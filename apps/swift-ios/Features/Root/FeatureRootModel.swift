import Foundation
import Observation

private struct FeatureConnectionUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Could not connect to the selected computer."
    }
}

enum FeatureDetailRenderChange: Equatable {
    case full
    case delta(FeatureDetailDelta)
}

struct FeatureDetailRenderUpdate: Equatable {
    let baseRevision: UInt64
    let revision: UInt64
    let change: FeatureDetailRenderChange
}

enum FeatureThreadLoadState: Equatable {
    case loading
    case failed(String)
}

@MainActor
@Observable
public final class FeatureRootModel {
    private static let maximumRetainedThreadDetails = 6

    private struct PendingSettlementMutation {
        let id: UUID
        let settled: Bool
        let settledAt: Date?
        let unsettledAt: Date?

        func apply(to thread: inout FeatureThread) {
            thread.isSettled = settled
            thread.keepsActive = !settled
            thread.settlementFacts?.settlementOverride = settled ? .settled : .active
            thread.settledAt = settledAt
            thread.unsettledAt = unsettledAt
            if settled {
                thread.pinnedAt = nil
            }
        }
    }

    public private(set) var snapshot = FeatureSnapshot()
    private(set) var pullRequestsByThreadID: [String: HomeThreadPullRequestPresentation] = [:]
    private var pullRequestObservationIdentities: [String: String] = [:]
    public private(set) var details: [String: FeatureThreadDetail] = [:]
    private(set) var detailLoadStates: [String: FeatureThreadLoadState] = [:]
    private var selectedThreadID: String?
    private var renderWindowByThread: [String: Int] = [:]
    private var warmedThreadIDs: Set<String> = []
    private var warmQueue: [String] = []
    private var warmTask: Task<Void, Never>?
    private var selectedThreadLoad: Task<Void, Never>?
    /// Advances whenever a Home presentation input changes.
    public private(set) var homePresentationRevision: UInt64 = 0
    /// Advances when a Home-visible thread is inserted, removed, or changed.
    public private(set) var threadCollectionRevision: UInt64 = 0
    /// Advances for any selected-thread metadata, message, approval, or input change.
    public private(set) var detailRevision: UInt64 = 0
    /// The latest detail revision for each loaded thread.
    public private(set) var detailRevisions: [String: UInt64] = [:]
    private(set) var detailRenderUpdates: [String: FeatureDetailRenderUpdate] = [:]
    public private(set) var isLoading = true
    public private(set) var isPerformingAction = false
    public private(set) var isManagingConnections = false
    private(set) var isSigningOutT3Connect = false
    public var errorMessage: String?

    let client: any FeatureClient
    private let outboxStore: FeatureOutboxStore
    private let draftStore: FeatureComposerDraftStore
    @ObservationIgnored
    public private(set) lazy var attachmentUploads = FeatureAttachmentUploadCoordinator(
        client: client,
        draftStore: draftStore
    )
    private var pendingSubmissionsByID: [String: FeatureQueuedSubmission] = [:]
    private var pendingThreadsByID: [String: FeatureThread] = [:]
    private var pendingSettlementMutations: [String: PendingSettlementMutation] = [:]
    private var pendingCompletionSubmissionIDs: Set<String> = []
    private var pendingDiscardSubmissionIDs: Set<String> = []
    private var detailRecency: [String] = []
    private var detailLoadGeneration: UInt64 = 0
    private var detailLoadRevisions: [String: UInt64] = [:]
    private var detailLoadRequestRevision: UInt64 = 0
    private var activeDetailLoadRequests: [String: UInt64] = [:]
    private var storedDetailLoadRequestRevisions: [String: UInt64] = [:]
    private var detailMetadataRevisions: [String: UInt64] = [:]
    private var outboxDrainTask: Task<Void, Never>?
    private var outboxRetryAttempt = 0
    private var outboxGeneration: UInt64 = 0

    public init(
        client: any FeatureClient,
        outboxStore: FeatureOutboxStore = .shared,
        draftStore: FeatureComposerDraftStore = .shared
    ) {
        self.client = client
        self.outboxStore = outboxStore
        self.draftStore = draftStore
    }

    public func start() async {
        // Show the last thread list immediately. `initialSnapshot()` reaches
        // every environment before it returns, so waiting on it leaves the home
        // screen empty for as long as the slowest computer takes to answer.
        if let cached = await client.cachedSnapshot() {
            install(cached)
            isLoading = false
        }
        do {
            install(try await client.initialSnapshot())
        } catch {
            if !Self.isBenignCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
        await restoreOutbox()
        isLoading = false
        scheduleOutboxDrain()

        for await event in client.events() {
            apply(event)
        }
    }

    public func reload() async {
        do {
            install(try await client.initialSnapshot())
        } catch {
            if !Self.isBenignCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Background refresh is deliberately separate from `reload()`: native
    /// clients must not mount WebSocket streams or timers for a bounded BG task.
    public func refreshInBackground() async -> Bool {
        do {
            install(try await client.backgroundSnapshot())
            return !Task.isCancelled
        } catch {
            if !Self.isBenignCancellation(error) {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    @discardableResult
    public func refreshProviders(environmentID: String) async -> Bool {
        await perform {
            let providers = try await client.refreshProviders(environmentID: environmentID)
            var byEnvironment = snapshot.providersByEnvironment ?? [:]
            byEnvironment[environmentID] = providers
            snapshot.providersByEnvironment = byEnvironment
        }
    }

    public func reloadAfterConnection() async {
        clearDetails()
        await reload()
    }

    public func pair(endpoint: String, token: String?) async -> Bool {
        await perform {
            try await client.pair(endpoint: endpoint, token: token)
            let next = try await client.initialSnapshot()
            clearDetails()
            install(next)
            guard next.connection.state != .disconnected else {
                throw FeatureConnectionUnavailableError()
            }
        }
    }

    public func removeEnvironment(_ id: String) async {
        var logicalProjectIDs = Set<String>(snapshot.projects.compactMap { project in
            guard project.environmentID == id, project.repositoryIdentity != nil else {
                return nil
            }
            return DailyUXCreationContext.logicalProjectID(for: project, in: snapshot)
        })
        let remainingLogicalProjectIDs = Set<String>(snapshot.projects.compactMap { project in
            guard project.environmentID != id, project.repositoryIdentity != nil else {
                return nil
            }
            return DailyUXCreationContext.logicalProjectID(for: project, in: snapshot)
        })
        logicalProjectIDs.subtract(remainingLogicalProjectIDs)
        await stopOutboxDrain()
        await perform {
            try await client.removeEnvironment(id: id)
            var cleanupError: (any Error)?
            do {
                try await outboxStore.removeAll(environmentID: id)
                removePendingSubmissions(environmentID: id)
            } catch {
                markPendingSubmissionsForDiscard(environmentID: id)
                cleanupError = error
            }
            do {
                try await draftStore.removeDrafts(
                    environmentID: id,
                    logicalProjectIDs: logicalProjectIDs
                )
            } catch {
                cleanupError = cleanupError ?? error
            }
            if let cleanupError {
                errorMessage = "Environment removed, but its queued messages or drafts could not be cleared: \(cleanupError.localizedDescription)"
            }
            install(try await client.initialSnapshot())
            clearDetails()
        }
        scheduleOutboxDrain()
    }

    public func signOutT3Connect() async {
        guard let capability = client as? any T3ConnectCapable else { return }
        isSigningOutT3Connect = true
        defer { isSigningOutT3Connect = false }
        let removedEnvironmentIDs = snapshot.environments
            .filter { $0.source == .t3Connect }
            .map(\.id)
        let removedEnvironmentIDSet = Set(removedEnvironmentIDs)
        let groupedProjects = Dictionary(
            grouping: snapshot.projects.filter { $0.repositoryIdentity != nil },
            by: \.environmentID
        )
        let retainedLogicalProjectIDs = Set<String>(snapshot.projects.compactMap { project in
            guard project.repositoryIdentity != nil,
                  !removedEnvironmentIDSet.contains(project.environmentID) else {
                return nil
            }
            return DailyUXCreationContext.logicalProjectID(for: project, in: snapshot)
        })
        let logicalProjectIDs = removedEnvironmentIDs.reduce(into: [String: Set<String>]()) {
            result, environmentID in
            let projectIDs = Set((groupedProjects[environmentID] ?? []).map {
                DailyUXCreationContext.logicalProjectID(for: $0, in: snapshot)
            })
            result[environmentID] = projectIDs.subtracting(retainedLogicalProjectIDs)
        }

        await stopOutboxDrain()
        await capability.signOutT3Connect()
        for environmentID in removedEnvironmentIDs {
            var cleanupError: (any Error)?
            do {
                try await outboxStore.removeAll(environmentID: environmentID)
            } catch {
                cleanupError = error
            }
            removePendingSubmissions(environmentID: environmentID)
            do {
                try await draftStore.removeDrafts(
                    environmentID: environmentID,
                    logicalProjectIDs: logicalProjectIDs[environmentID] ?? []
                )
            } catch {
                cleanupError = cleanupError ?? error
            }
            if let cleanupError {
                errorMessage = "Could not clear saved T3 Connect data: \(cleanupError.localizedDescription)"
            }
        }
        clearDetails()
        await reload()
        scheduleOutboxDrain()
    }

    func removeManagedEnvironmentsAfterAccountChange() async {
        let managedIDs = snapshot.environments
            .filter { $0.source == .t3Connect }
            .map(\.id)
        for id in managedIDs {
            await removeEnvironment(id)
        }
    }

    @discardableResult
    public func setEnvironmentEnabled(_ id: String, enabled: Bool) async -> Bool {
        await stopOutboxDrain()
        let succeeded = await perform {
            try await client.setEnvironmentEnabled(id: id, enabled: enabled)
            install(try await client.initialSnapshot())
            if !enabled { clearDetails() }
        }
        scheduleOutboxDrain()
        return succeeded
    }

    public func disconnect() async {
        await stopOutboxDrain()
        isManagingConnections = false
        await client.disconnect()
        let disconnectedEnvironments = snapshot.environments.map { environment in
            var environment = environment
            environment.connectionState = .disconnected
            environment.connectionDetail = nil
            return environment
        }
        install(FeatureSnapshot(
            environments: disconnectedEnvironments,
            settings: snapshot.settings
        ))
        clearDetails()
    }

    public func setConnectionManagementPresented(_ isPresented: Bool) {
        isManagingConnections = isPresented
    }

    public func addProject(path: String) async -> Bool {
        await perform {
            try await client.addProject(path: path)
            install(try await client.initialSnapshot())
        }
    }

    public func createThread(
        projectID: String,
        title: String?,
        selection: FeatureSelection?
    ) async -> FeatureThread? {
        let environment = currentEnvironmentIdentity
        var created: FeatureThread?
        let succeeded = await perform {
            let thread = try await client.createThread(
                projectID: projectID,
                title: title,
                selection: selection
            )
            guard currentEnvironmentIdentity == environment else {
                throw CancellationError()
            }
            upsert(thread)
            created = thread
        }
        return succeeded ? created : nil
    }

    public func startTask(_ request: NewTaskRequest) async -> FeatureThread? {
        let prompt = request.trimmedPrompt
        guard !prompt.isEmpty || !request.attachments.isEmpty else { return nil }
        guard request.workspaceMode != .worktree || request.branch != nil else { return nil }

        guard let project = snapshot.projects.first(where: { $0.id == request.projectID }) else {
            errorMessage = "That project is no longer available."
            return nil
        }
        let identity = FeatureSubmissionIdentity()
        let threadID = FeatureScopedID.thread(
            environmentID: project.environmentID,
            wireID: identity.threadID
        )
        let uploads = request.attachments.map(\.upload)
        let queued = FeatureQueuedSubmission(
            environmentID: project.environmentID,
            identity: identity,
            threadID: threadID,
            text: prompt,
            selection: request.selection,
            runtimeMode: request.runtimeMode,
            interactionMode: request.interactionMode,
            attachments: uploads,
            creation: FeatureQueuedCreation(
                projectID: request.projectID,
                projectName: project.name,
                workspaceMode: request.workspaceMode,
                branch: request.branch,
                worktreePath: request.worktreePath,
                startFromOrigin: request.startFromOrigin
            )
        )
        guard await enqueue(queued) else { return nil }
        installPendingCreation(queued, project: project)

        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let thread = try await client.createThreadAndSend(
                projectID: request.projectID,
                prompt: prompt,
                selection: request.selection,
                runtimeMode: request.runtimeMode,
                interactionMode: request.interactionMode.mobileNormalized,
                workspaceMode: request.workspaceMode,
                branch: request.branch,
                worktreePath: request.worktreePath,
                startFromOrigin: request.startFromOrigin,
                attachments: uploads,
                identity: identity
            )
            if !(await completeQueuedSubmission(queued)) {
                scheduleOutboxRetry()
            }
            if thread.id != queued.threadID {
                removeThread(id: queued.threadID)
                removeDetail(id: queued.threadID)
            }
            upsert(thread)
            return thread
        } catch {
            if Self.shouldQueue(error, environmentID: project.environmentID, snapshot: snapshot) {
                if isEnvironmentConnected(project.environmentID) {
                    scheduleOutboxRetry()
                }
                return snapshot.threads.first { $0.id == threadID }
                    ?? pendingThreadsByID[threadID]
            }
            let discarded = await discardQueuedSubmission(queued)
            if !discarded {
                scheduleOutboxRetry()
            }
            if discarded, !Self.isBenignCancellation(error) {
                errorMessage = error.localizedDescription
            }
            return nil
        }
    }

    public func workspaceBranches(
        projectID: String,
        refresh: Bool = false
    ) async throws -> [FeatureWorkspaceBranch] {
        try await client.listWorkspaceBranches(projectID: projectID, refresh: refresh)
    }

    public func renameThread(_ id: String, title: String) async {
        let environment = currentEnvironmentIdentity
        await perform {
            try await client.renameThread(id: id, title: title)
            guard currentEnvironmentIdentity == environment else { return }
            mutateThread(id: id) { $0.title = title }
        }
    }

    public func regenerateThreadTitle(_ id: String) async {
        await perform {
            try await client.regenerateThreadTitle(id: id)
        }
    }

    public func setArchived(_ id: String, archived: Bool) async {
        if archived,
           let thread = snapshot.threads.first(where: { $0.id == id }),
           [.queued, .working, .monitoring, .waitingForApproval, .waitingForInput]
               .contains(thread.state) {
            errorMessage = "This thread is still active. Stop it before archiving."
            return
        }
        let environment = currentEnvironmentIdentity
        await perform {
            try await client.setThreadArchived(id: id, archived: archived)
            guard currentEnvironmentIdentity == environment else { return }
            mutateThread(id: id) { $0.isArchived = archived }
        }
    }

    @discardableResult
    public func setSettled(_ id: String, settled: Bool) async -> Bool {
        guard let previous = snapshot.threads.first(where: { $0.id == id }) else {
            return false
        }
        if settled, !previous.canSettleNow() {
            errorMessage = "This thread still needs attention. Resolve or stop it first."
            return false
        }

        let environment = currentEnvironmentIdentity
        let now = Date.now
        let mutation = PendingSettlementMutation(
            id: UUID(),
            settled: settled,
            settledAt: settled ? now : nil,
            unsettledAt: settled ? nil : now
        )
        pendingSettlementMutations[id] = mutation
        mutateThread(id: id) { mutation.apply(to: &$0) }

        let succeeded = await perform {
            try await client.setThreadSettled(id: id, settled: settled)
        }

        guard pendingSettlementMutations[id]?.id == mutation.id else { return false }
        pendingSettlementMutations.removeValue(forKey: id)
        guard !succeeded else { return true }
        guard currentEnvironmentIdentity == environment else { return false }

        mutateThread(id: id) {
            guard $0.isSettled == settled, $0.settledAt == mutation.settledAt else { return }
            $0.isSettled = previous.isSettled
            $0.keepsActive = previous.keepsActive
            $0.settlementFacts?.settlementOverride = previous.settlementFacts?.settlementOverride
            $0.settledAt = previous.settledAt
            $0.unsettledAt = previous.unsettledAt
            $0.pinnedAt = previous.pinnedAt
        }
        return false
    }

    public func setSnoozed(_ id: String, until: Date?) async {
        let environment = currentEnvironmentIdentity
        await perform {
            try await client.setThreadSnoozed(id: id, until: until)
            guard currentEnvironmentIdentity == environment else { return }
            let snoozedAt = until.map { _ in Date.now }
            mutateThread(id: id) {
                $0.snoozedUntil = until
                $0.snoozedAt = snoozedAt
            }
        }
    }

    public func setPinned(_ id: String, pinned: Bool) async {
        let environment = currentEnvironmentIdentity
        await perform {
            try await client.setThreadPinned(id: id, pinned: pinned)
            guard currentEnvironmentIdentity == environment else { return }
            mutateThread(id: id) {
                $0.pinnedAt = pinned ? Date.now : nil
                if pinned {
                    $0.snoozedUntil = nil
                    $0.snoozedAt = nil
                }
            }
        }
    }

    func updatePullRequest(
        _ pullRequest: HomeThreadPullRequestPresentation?,
        threadID: String,
        observationIdentity: String
    ) {
        guard snapshot.threads.first(where: { $0.id == threadID })?
            .pullRequestObservationIdentity == observationIdentity else {
            return
        }
        if pullRequest == nil, pullRequestsByThreadID[threadID] == nil { return }
        if pullRequestsByThreadID[threadID] == pullRequest,
           pullRequestObservationIdentities[threadID] == observationIdentity {
            return
        }
        if let pullRequest {
            pullRequestsByThreadID[threadID] = pullRequest
            pullRequestObservationIdentities[threadID] = observationIdentity
        } else {
            pullRequestsByThreadID.removeValue(forKey: threadID)
            pullRequestObservationIdentities.removeValue(forKey: threadID)
        }
        homePresentationRevision &+= 1
    }

    func isEffectivelySettled(_ thread: FeatureThread) -> Bool {
        thread.isEffectivelySettled()
    }

    public func setRuntimeMode(_ id: String, mode: FeatureRuntimeMode) async {
        guard let environmentID = snapshot.threads.first(where: { $0.id == id })?.environmentID else {
            return
        }
        await perform {
            try await client.setRuntimeMode(id: id, mode: mode)
            guard snapshot.threads.first(where: { $0.id == id })?.environmentID == environmentID else {
                return
            }
            mutateThread(id: id) { $0.runtimeMode = mode }
        }
    }

    public func setInteractionMode(_ id: String, mode: FeatureInteractionMode) async {
        let mode = mode.mobileNormalized
        let environment = currentEnvironmentIdentity
        await perform {
            try await client.setInteractionMode(id: id, mode: mode)
            guard currentEnvironmentIdentity == environment else { return }
            mutateThread(id: id) { $0.interactionMode = mode }
        }
    }

    public func deleteThread(_ id: String) async {
        let environment = currentEnvironmentIdentity
        await perform {
            try await client.deleteThread(id: id)
            guard currentEnvironmentIdentity == environment else { return }
            removeThread(id: id)
            removeDetail(id: id)
        }
    }

    public func detail(for id: String, force: Bool = false) async -> FeatureThreadDetail? {
        if !force, let cached = details[id] {
            return cached
        }
        let environment = currentEnvironmentIdentity
        let loadGenerationBeforeLoad = detailLoadGeneration
        let loadRevisionBeforeLoad = detailLoadRevisions[id]
        let metadataRevisionBeforeLoad = detailMetadataRevisions[id]
        let threadBeforeLoad = snapshot.threads.first { $0.id == id }
        detailLoadRequestRevision &+= 1
        let loadRequestRevision = detailLoadRequestRevision
        activeDetailLoadRequests[id] = loadRequestRevision
        detailLoadStates[id] = .loading
        defer {
            if activeDetailLoadRequests[id] == loadRequestRevision {
                activeDetailLoadRequests[id] = nil
                if detailLoadStates[id] == .loading {
                    detailLoadStates[id] = nil
                }
            }
        }
        do {
            var detail = try await client.loadThread(id: id)
            guard currentEnvironmentIdentity == environment else {
                return details[id]
            }
            if detailLoadGeneration != loadGenerationBeforeLoad
                || detailLoadRevisions[id] != loadRevisionBeforeLoad {
                return details[id]
            }
            if let storedLoadRequestRevision = storedDetailLoadRequestRevisions[id],
               loadRequestRevision < storedLoadRequestRevision {
                return details[id]
            }
            let currentThread = snapshot.threads.first { $0.id == id }
            if detailMetadataRevisions[id] != metadataRevisionBeforeLoad {
                if let currentThread = details[id]?.thread ?? currentThread {
                    detail.thread = currentThread
                }
            } else if let currentThread, currentThread != threadBeforeLoad {
                detail.thread = currentThread
            }
            store(detail, invalidatesInFlightLoad: false)
            storedDetailLoadRequestRevisions[id] = loadRequestRevision
            upsert(detail.thread)
            return detail
        } catch {
            if !Self.isBenignCancellation(error),
               activeDetailLoadRequests[id] == loadRequestRevision,
               detailLoadGeneration == loadGenerationBeforeLoad,
               detailLoadRevisions[id] == loadRevisionBeforeLoad,
               currentEnvironmentIdentity == environment {
                detailLoadStates[id] = .failed(error.localizedDescription)
                if details[id] == nil {
                    errorMessage = error.localizedDescription
                }
            }
            return details[id]
        }
    }

    /// How many older messages a single scrollback step pulls from disk.
    ///
    /// Small on purpose. Each page is inserted above the reader, which shifts
    /// every index path below it, and compositional layout caches self-sizing
    /// measurements by index path — so a page costs a re-measure whatever its
    /// size. Ten keeps each of those short enough to disappear into the scroll
    /// rather than landing as one long stall.
    private static let storedEarlierMessageLimit = 10

    public func loadEarlierTurns(for id: String) async {
        guard details[id]?.page?.hasMore == true,
              details[id]?.page?.isLoading != true else { return }
        // Disk first. History already synced is on the device; `hasMore` only
        // describes what the server holds beyond what was ever fetched, so
        // without this the reader waits on the network for turns already local.
        if let current = details[id], let oldest = current.messages.first {
            let older = await client.storedMessages(
                before: oldest.id,
                threadID: id,
                limit: Self.storedEarlierMessageLimit
            )
            if !older.isEmpty {
                renderWindowByThread[id] = renderWindow(for: id) + older.count
                var next = current
                next.messages = older + current.messages
                store(next, invalidatesInFlightLoad: false)
                return
            }
        }
        let environment = currentEnvironmentIdentity
        do {
            guard let detail = try await client.loadEarlierThreadTurns(id: id),
                  currentEnvironmentIdentity == environment else { return }
            let added = detail.messages.count - (details[id]?.messages.count ?? 0)
            if added > 0 {
                renderWindowByThread[id] = renderWindow(for: id) + added
            }
            store(detail, invalidatesInFlightLoad: false)
        } catch {
            if !Self.isBenignCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Selection owns thread loading and subscription, not view lifecycle.
    /// The compact split view re-hosts the detail column when it opens, which
    /// cancelled any view-scoped load and left the thread showing its previous
    /// contents with no stream until it was opened a second time.
    /// `isLoaded` is set by callers that already fetched the thread before
    /// navigating to it. Reloading in that case would replace the content the
    /// screen just opened with, which is visible as the transcript rebuilding
    /// underneath the reader.
    /// The thread as last persisted, adopted into `details` so the UI can open
    /// it with no network in the path. Never overwrites content already in
    /// memory, which is fresher by definition.
    /// How many messages the transcript renders while the reader is at the
    /// newest message.
    ///
    /// `UICollectionViewCompositionalLayout` recomputes the whole section on
    /// every update — measured at ~0.13ms per row, so 247 rows cost ~32ms to
    /// append one message to, several times a second while an agent streams.
    /// Sixty rows keeps that inside a 120Hz frame, and makes even a full
    /// rebuild cheap enough that the incremental path stops mattering.
    private static let liveWindowMessageLimit = 60

    /// How many messages a thread currently renders.
    ///
    /// Deliberately not derived from scroll position. An earlier version
    /// collapsed the window whenever the reader was at the newest message, but
    /// collapsing changes `contentSize`, which changes the position reading,
    /// which flipped the decision straight back — the transcript oscillated
    /// between 60 and 265 rows several times a second, rebuilding each time.
    /// The window only grows when the reader explicitly pages back.
    private func renderWindow(for id: String) -> Int {
        renderWindowByThread[id] ?? Self.liveWindowMessageLimit
    }

    private func trimmedToWindow(_ detail: FeatureThreadDetail) -> FeatureThreadDetail {
        let limit = renderWindow(for: detail.thread.id)
        guard detail.messages.count > limit else { return detail }
        var trimmed = detail
        trimmed.messages = Array(detail.messages.suffix(limit))
        return trimmed
    }

    public func storedDetail(for id: String) async -> FeatureThreadDetail? {
        if let cached = details[id] { return cached }
        guard let stored = await client.storedThread(id: id) else { return nil }
        guard details[id] == nil else { return details[id] }
        store(stored, invalidatesInFlightLoad: false)
        return details[id]
    }

    /// Brings the local store up to date as soon as the thread list lands, so a
    /// thread is already current when it is tapped rather than starting to load
    /// then. Bounded to the threads a reader is realistically about to open —
    /// syncing everything would put the whole account on the websocket, which
    /// remote and relay connections cannot afford.
    public func warmThreads(limit: Int = 30) {
        warmThreads(
            snapshot.threads
                .filter { !$0.isArchived }
                .sorted { ($0.lastActivityAt ?? $0.updatedAt) > ($1.lastActivityAt ?? $1.updatedAt) }
                .prefix(limit)
                .map(\.id)
        )
    }

    /// Queues threads to bring up to date on disk. Requests accumulate rather
    /// than being dropped while one is in flight, so a thread list that arrives
    /// in pieces still ends up fully warmed — the previous one-shot version
    /// silently skipped everything that arrived during the first pass.
    public func warmThreads(_ ids: [String]) {
        let additions = ids.filter {
            !warmedThreadIDs.contains($0) && !warmQueue.contains($0)
        }
        guard !additions.isEmpty else { return }
        warmQueue.append(contentsOf: additions)
        guard warmTask == nil else { return }
        warmTask = Task { [weak self] in
            while let next = self?.dequeueThreadToWarm() {
                guard !Task.isCancelled else { break }
                await self?.client.warmThread(id: next)
            }
            // History comes second. Warming makes every thread openable; the
            // backfill that follows makes them complete, and would otherwise
            // hold the socket while the threads a reader can see are still
            // empty.
            for id in self?.warmedThreadIDs.sorted() ?? [] {
                guard !Task.isCancelled else { break }
                await self?.client.backfillThread(id: id)
            }
            self?.warmTask = nil
        }
    }

    private func dequeueThreadToWarm() -> String? {
        guard !warmQueue.isEmpty else { return nil }
        let id = warmQueue.removeFirst()
        warmedThreadIDs.insert(id)
        return id
    }

    public func selectThread(_ id: String?, isLoaded: Bool = false) {
        guard selectedThreadID != id else { return }
        selectedThreadLoad?.cancel()
        selectedThreadLoad = nil
        if let previous = selectedThreadID {
            releaseThread(previous)
        }
        if let previous = selectedThreadID {
            renderWindowByThread.removeValue(forKey: previous)
        }
        selectedThreadID = id
        guard let id else { return }
        selectedThreadLoad = Task { [weak self] in
            guard let self else { return }
            // Resume from disk when we can: the server replays only what we
            // missed, so the transcript on screen is extended rather than
            // replaced. A full load re-sends the most recent page, which is a
            // different message set to whatever is already rendered.
            if let resumed = await self.client.resumeThread(id: id) {
                self.store(resumed, invalidatesInFlightLoad: false)
                self.upsert(resumed.thread)
                return
            }
            guard !isLoaded else { return }
            _ = await self.detail(for: id, force: true)
        }
    }

    /// Ends any selected-thread transport work when its detail view closes.
    public func releaseThread(_ id: String) {
        client.releaseThread(id: id)
        markDetailRecentlyUsed(id)
        evictOldThreadDetailsIfNeeded()
    }

    public func sendMessage(threadID: String, text: String, selection: FeatureSelection?) async -> Bool {
        await sendMessage(
            FeatureMessageSubmission(
                threadID: threadID,
                text: text,
                selection: selection
            )
        )
    }

    public func sendMessage(_ submission: FeatureMessageSubmission) async -> Bool {
        let trimmed = submission.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !submission.attachments.isEmpty else { return false }

        guard let thread = snapshot.threads.first(where: { $0.id == submission.threadID }),
              let environmentID = thread.environmentID else {
            return false
        }
        let identity = FeatureSubmissionIdentity(threadID: thread.wireID ?? thread.id)
        let uploads = submission.attachments.map(\.upload)
        let queued = FeatureQueuedSubmission(
            environmentID: environmentID,
            identity: identity,
            threadID: submission.threadID,
            text: trimmed,
            selection: submission.selection,
            runtimeMode: thread.runtimeMode,
            interactionMode: thread.interactionMode,
            attachments: uploads
        )
        guard await enqueue(queued) else { return false }

        let optimistic = FeatureMessage(
            id: identity.messageID,
            role: .user,
            text: trimmed,
            createdAt: identity.createdAt,
            state: .queued,
            attachments: submission.attachments.map {
                FeatureMessageAttachment(
                    id: $0.id.uuidString,
                    name: $0.filename,
                    mimeType: $0.mimeType,
                    sizeBytes: $0.byteCount,
                    previewData: $0.thumbnailData
                )
            }
        )
        mutateDetail(
            id: submission.threadID,
            change: .delta(FeatureDetailDelta(
                changedMessages: [optimistic],
                appendedMessageIDs: [optimistic.id]
            ))
        ) {
            $0.messages.append(optimistic)
        }

        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await client.sendMessage(
                threadID: submission.threadID,
                text: trimmed,
                selection: submission.selection,
                runtimeMode: queued.runtimeMode,
                attachments: uploads,
                identity: identity
            )
            if !(await completeQueuedSubmission(queued)) {
                scheduleOutboxRetry()
            }
            return true
        } catch {
            if Self.shouldQueue(error, environmentID: environmentID, snapshot: snapshot) {
                if isEnvironmentConnected(environmentID) {
                    scheduleOutboxRetry()
                }
                return true
            }
            let discarded = await discardQueuedSubmission(queued)
            if !discarded {
                scheduleOutboxRetry()
            }
            if discarded, !Self.isBenignCancellation(error) {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    public func cancelTurn(threadID: String) async {
        if pendingSubmissionsByID.values.contains(where: {
            $0.threadID == threadID && $0.creation != nil
        }) {
            await stopOutboxDrain()
            let queued = pendingSubmissionsByID.values.filter { $0.threadID == threadID }
            for submission in queued {
                if !(await discardQueuedSubmission(submission)) {
                    scheduleOutboxRetry()
                }
            }
            if pendingThreadsByID[threadID] == nil,
               snapshot.threads.contains(where: { $0.id == threadID }) {
                await perform {
                    try await client.cancelTurn(threadID: threadID)
                }
            }
            scheduleOutboxDrain()
            return
        }
        await perform {
            try await client.cancelTurn(threadID: threadID)
        }
    }

    public func resolveApproval(_ id: String, decision: FeatureApprovalDecision) async {
        let environment = currentEnvironmentIdentity
        await perform {
            try await client.resolveApproval(id: id, decision: decision)
            guard currentEnvironmentIdentity == environment else { return }
            // Only touch details that actually hold the request; mutateDetail
            // deep-compares each mutated detail and the cache never shrinks.
            for key in Array(details.keys)
                where details[key]?.approvals.contains(where: { $0.id == id }) == true {
                mutateDetail(
                    id: key,
                    change: .delta(FeatureDetailDelta(changedMessages: []))
                ) {
                    $0.approvals.removeAll { $0.id == id }
                }
            }
        }
    }

    public func resolveUserInput(_ id: String, answers: [String: FeatureInputAnswer]) async {
        let environment = currentEnvironmentIdentity
        await perform {
            try await client.resolveUserInput(id: id, answers: answers)
            guard currentEnvironmentIdentity == environment else { return }
            for key in Array(details.keys)
                where details[key]?.userInputs.contains(where: { $0.id == id }) == true {
                mutateDetail(
                    id: key,
                    change: .delta(FeatureDetailDelta(changedMessages: []))
                ) {
                    $0.userInputs.removeAll { $0.id == id }
                }
            }
        }
    }

    /// Convenience for callers that only submit free-form or single-select text.
    public func resolveUserInput(_ id: String, answers: [String: String]) async {
        await resolveUserInput(
            id,
            answers: answers.mapValues(FeatureInputAnswer.text)
        )
    }

    @discardableResult
    public func saveSettings(_ settings: FeatureSettings) async -> Bool {
        await perform {
            try await client.saveSettings(settings)
            snapshot.settings = settings
        }
    }

    @discardableResult
    public func updateAutomaticSettlement(
        environmentID: String,
        change: FeatureAutomaticSettlementChange
    ) async -> Bool {
        await perform {
            let updated = try await client.updateAutomaticSettlement(
                environmentID: environmentID,
                change: change
            )
            guard var preferences = snapshot.preferencesByEnvironment?[environmentID],
                  preferences.automaticSettlement != nil else {
                return
            }
            preferences.automaticSettlement = updated
            snapshot.preferencesByEnvironment?[environmentID] = preferences
        }
    }

    /// Applies appearance optimistically so selecting a theme updates every
    /// surface immediately, then persists just that preference in the current
    /// settings snapshot. Other unsaved Settings edits remain drafts.
    @discardableResult
    public func saveAppearance(_ appearance: FeatureAppearance) async -> Bool {
        let previous = snapshot.settings
        guard previous.appearance != appearance else { return true }

        var updated = previous
        updated.appearance = appearance
        snapshot.settings = updated

        do {
            try await client.saveSettings(updated)
            return true
        } catch {
            if snapshot.settings == updated {
                snapshot.settings = previous
            }
            if !Self.isBenignCancellation(error) {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    @discardableResult
    private func perform(
        reportError: Bool = true,
        _ operation: () async throws -> Void
    ) async -> Bool {
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await operation()
            return true
        } catch {
            if reportError, !Self.isBenignCancellation(error) {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private static func isBenignCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let message = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return message == "cancelled" || message == "canceled"
    }

    private var currentEnvironmentIdentity: String {
        snapshot.environments
            .sorted { $0.id < $1.id }
            .map { "\($0.id)|\($0.endpoint)|\($0.isEnabled)" }
            .joined(separator: ";")
    }

    private func apply(_ event: FeatureEvent) {
        switch event {
        case let .snapshot(value):
            install(value)
            warmThreads()
        case let .connection(value):
            guard snapshot.connection != value else { return }
            snapshot.connection = value
            homePresentationRevision &+= 1
            if value.state == .connected {
                scheduleOutboxDrain()
            }
        case let .thread(value):
            pendingThreadsByID.removeValue(forKey: value.id)
            upsert(value)
        case let .threadRemoved(id):
            removeThread(id: id)
            removeDetail(id: id)
        case let .detail(value):
            pendingThreadsByID.removeValue(forKey: value.thread.id)
            store(value)
            upsert(value.thread)
        case let .detailDelta(value, delta):
            pendingThreadsByID.removeValue(forKey: value.thread.id)
            store(value, delta: delta)
            upsert(value.thread)
        case let .failure(message):
            errorMessage = message
        }
    }

    private func upsert(_ thread: FeatureThread) {
        let thread = retainingPendingSettlement(in: thread)
        discardStalePullRequest(for: thread)
        var metadataChanged = false
        if let index = snapshot.threads.firstIndex(where: { $0.id == thread.id }) {
            let previous = snapshot.threads[index]
            // Settling is the point a thread stops being worked on, so its older
            // turns stop earning their disk. Trim once, on the transition.
            if !previous.isSettled, thread.isSettled {
                Task { [client] in await client.pruneThread(id: thread.id) }
            }
            if previous != thread {
                snapshot.threads[index] = thread
                metadataChanged = true
                if previous.projectID != thread.projectID {
                    adjustProjectCount(id: previous.projectID, by: -1)
                    adjustProjectCount(id: thread.projectID, by: 1)
                }
            }
        } else {
            snapshot.threads.append(thread)
            adjustProjectCount(id: thread.projectID, by: 1)
            metadataChanged = true
        }
        if metadataChanged {
            threadCollectionRevision &+= 1
            homePresentationRevision &+= 1
        }
        let detailChanged = mutateDetail(
            id: thread.id,
            change: .delta(FeatureDetailDelta(changedMessages: [])),
            invalidatesInFlightLoad: false
        ) {
            $0.thread = thread
        }
        if metadataChanged || detailChanged {
            bumpDetailMetadataRevision(id: thread.id)
        }
    }

    private func removeThread(id: String) {
        guard let index = snapshot.threads.firstIndex(where: { $0.id == id }) else { return }
        let projectID = snapshot.threads[index].projectID
        snapshot.threads.remove(at: index)
        pullRequestsByThreadID.removeValue(forKey: id)
        pullRequestObservationIdentities.removeValue(forKey: id)
        adjustProjectCount(id: projectID, by: -1)
        threadCollectionRevision &+= 1
        homePresentationRevision &+= 1
    }

    private func adjustProjectCount(id: String, by delta: Int) {
        guard let index = snapshot.projects.firstIndex(where: { $0.id == id }) else { return }
        snapshot.projects[index].threadCount = max(0, snapshot.projects[index].threadCount + delta)
    }

    private func install(_ value: FeatureSnapshot) {
        var value = value
        for index in value.threads.indices {
            value.threads[index] = retainingPendingSettlement(in: value.threads[index])
        }
        let authoritativeThreadIDs = Set(value.threads.map(\.id))
        for id in authoritativeThreadIDs {
            pendingThreadsByID.removeValue(forKey: id)
        }
        for pending in pendingThreadsByID.values where !authoritativeThreadIDs.contains(pending.id) {
            value.threads.append(pending)
            if let index = value.projects.firstIndex(where: { $0.id == pending.projectID }) {
                value.projects[index].threadCount += 1
            }
        }

        let previousThreads = snapshot.threads.reduce(into: [String: FeatureThread]()) {
            $0[$1.id] = $1
        }
        let nextThreads = value.threads.reduce(into: [String: FeatureThread]()) {
            $0[$1.id] = $1
        }
        for thread in value.threads {
            discardStalePullRequest(for: thread)
        }
        for id in Array(pullRequestsByThreadID.keys) where nextThreads[id] == nil {
            pullRequestsByThreadID.removeValue(forKey: id)
            pullRequestObservationIdentities.removeValue(forKey: id)
        }
        for id in previousThreads.keys where nextThreads[id] == nil {
            removeDetail(id: id)
        }
        for thread in value.threads where previousThreads[thread.id] != thread {
            mutateDetail(
                id: thread.id,
                change: .delta(FeatureDetailDelta(changedMessages: [])),
                invalidatesInFlightLoad: false
            ) {
                $0.thread = thread
            }
            bumpDetailMetadataRevision(id: thread.id)
        }

        if snapshot.connection != value.connection
            || snapshot.environments != value.environments
            || snapshot.projects != value.projects
            || snapshot.providers != value.providers
            || snapshot.providersByEnvironment != value.providersByEnvironment
            || snapshot.preferencesByEnvironment != value.preferencesByEnvironment
            || snapshot.threads != value.threads {
            homePresentationRevision &+= 1
        }
        if snapshot.threads != value.threads {
            threadCollectionRevision &+= 1
        }
        snapshot = value
        if value.connection.state == .connected
            || value.environments.contains(where: { $0.connectionState == .connected }) {
            scheduleOutboxDrain()
        }
    }

    private func discardStalePullRequest(for thread: FeatureThread) {
        guard let cachedIdentity = pullRequestObservationIdentities[thread.id],
              cachedIdentity != thread.pullRequestObservationIdentity else {
            return
        }
        pullRequestsByThreadID.removeValue(forKey: thread.id)
        pullRequestObservationIdentities.removeValue(forKey: thread.id)
    }

    private func mutateThread(
        id: String,
        _ mutation: (inout FeatureThread) -> Void
    ) {
        var metadataChanged = false
        if let index = snapshot.threads.firstIndex(where: { $0.id == id }) {
            let previous = snapshot.threads[index]
            mutation(&snapshot.threads[index])
            if snapshot.threads[index] != previous {
                metadataChanged = true
                threadCollectionRevision &+= 1
                homePresentationRevision &+= 1
            }
        }
        let detailChanged = mutateDetail(
            id: id,
            change: .delta(FeatureDetailDelta(changedMessages: [])),
            invalidatesInFlightLoad: false
        ) {
            mutation(&$0.thread)
        }
        if metadataChanged || detailChanged {
            bumpDetailMetadataRevision(id: id)
        }
    }

    private func store(
        _ incoming: FeatureThreadDetail,
        invalidatesInFlightLoad: Bool = true
    ) {
        var incoming = retainingLocalAttachmentPreviews(in: incoming)
        incoming.thread = retainingPendingSettlement(in: incoming.thread)
        let id = incoming.thread.id
        acknowledgeDeliveredMessages(incoming.messages)
        let prepared = addingPendingMessages(to: incoming)
        let next = details[id].map { current in
            FeatureThreadDetail(
                thread: prepared.thread,
                messages: mergingHistory(current.messages, with: prepared.messages),
                approvals: replacingChangedSuffix(current.approvals, with: prepared.approvals),
                userInputs: replacingChangedSuffix(current.userInputs, with: prepared.userInputs),
                page: prepared.page,
                activeSubagentCount: prepared.activeSubagentCount,
                backgroundWorkIsActive: prepared.backgroundWorkIsActive
            )
        } ?? prepared
        let windowed = trimmedToWindow(next)
        guard details[id] != windowed else { return }
        details[id] = windowed
        markDetailRecentlyUsed(id)
        if invalidatesInFlightLoad {
            bumpDetailLoadRevision(id: id)
        }
        bumpDetailRevision(id: id, change: .full)
    }

    private func store(_ incoming: FeatureThreadDetail, delta: FeatureDetailDelta) {
        var incoming = retainingLocalAttachmentPreviews(in: incoming)
        incoming.thread = retainingPendingSettlement(in: incoming.thread)
        let id = incoming.thread.id
        acknowledgeDeliveredMessages(incoming.messages)
        let next = addingPendingMessages(to: incoming)
        // The same window applies here as on the full path. The client keeps
        // publishing the whole transcript, so leaving this one uncapped let a
        // streamed delta re-expand what the full path had just trimmed, and the
        // two rebuilt the section against each other several times a second.
        let trimmed = trimmedToWindow(next)
        details[id] = trimmed
        markDetailRecentlyUsed(id)
        bumpDetailLoadRevision(id: id)
        guard trimmed.messages.count == next.messages.count else {
            // Trimming drops messages the delta does not describe, so the
            // renderer has to diff instead of applying it.
            bumpDetailRevision(id: id, change: .full)
            return
        }
        let appended = next.messages.dropFirst(incoming.messages.count).map(\.id)
        let pendingDelta = FeatureDetailDelta(
            changedMessages: delta.changedMessages + next.messages.dropFirst(incoming.messages.count),
            appendedMessageIDs: delta.appendedMessageIDs + appended
        )
        bumpDetailRevision(id: id, change: .delta(pendingDelta))
    }

    private func retainingPendingSettlement(in thread: FeatureThread) -> FeatureThread {
        guard let mutation = pendingSettlementMutations[thread.id] else { return thread }
        var thread = thread
        mutation.apply(to: &thread)
        return thread
    }

    @discardableResult
    private func mutateDetail(
        id: String,
        change: FeatureDetailRenderChange = .full,
        invalidatesInFlightLoad: Bool = true,
        _ mutation: (inout FeatureThreadDetail) -> Void
    ) -> Bool {
        guard var detail = details[id] else { return false }
        let previous = detail
        mutation(&detail)
        guard detail != previous else { return false }
        details[id] = detail
        markDetailRecentlyUsed(id)
        if invalidatesInFlightLoad {
            bumpDetailLoadRevision(id: id)
        }
        bumpDetailRevision(id: id, change: change)
        return true
    }

    private func removeDetail(id: String) {
        if details.removeValue(forKey: id) != nil {
            detailRecency.removeAll { $0 == id }
        }
        storedDetailLoadRequestRevisions.removeValue(forKey: id)
        activeDetailLoadRequests.removeValue(forKey: id)
        detailLoadStates.removeValue(forKey: id)
        bumpDetailLoadRevision(id: id)
        bumpDetailRevision(id: id, change: .full)
    }

    private func clearDetails() {
        warmedThreadIDs.removeAll()
        warmQueue.removeAll()
        warmTask?.cancel()
        warmTask = nil
        detailLoadGeneration &+= 1
        detailLoadRevisions.removeAll()
        storedDetailLoadRequestRevisions.removeAll()
        activeDetailLoadRequests.removeAll()
        detailLoadStates.removeAll()
        detailMetadataRevisions.removeAll()
        let hadDetails = !details.isEmpty
        details.removeAll()
        detailRecency.removeAll()
        if hadDetails {
            detailRevision &+= 1
        }
        detailRevisions.removeAll()
        detailRenderUpdates.removeAll()
    }

    private func bumpDetailLoadRevision(id: String) {
        detailLoadRevisions[id] = (detailLoadRevisions[id] ?? 0) &+ 1
    }

    private func bumpDetailMetadataRevision(id: String) {
        detailMetadataRevisions[id] = (detailMetadataRevisions[id] ?? 0) &+ 1
    }

    private func markDetailRecentlyUsed(_ id: String) {
        detailRecency.removeAll { $0 == id }
        detailRecency.append(id)
    }

    private func evictOldThreadDetailsIfNeeded() {
        let protected = Set(pendingSubmissionsByID.values.map(\.threadID))
        while details.count > Self.maximumRetainedThreadDetails,
              let candidate = detailRecency.first(where: { !protected.contains($0) }) {
            detailRecency.removeAll { $0 == candidate }
            removeDetail(id: candidate)
        }
    }

    private func bumpDetailRevision(id: String, change: FeatureDetailRenderChange) {
        let baseRevision = detailRevisions[id] ?? 0
        detailRevision &+= 1
        detailRevisions[id] = detailRevision
        detailRenderUpdates[id] = FeatureDetailRenderUpdate(
            baseRevision: baseRevision,
            revision: detailRevision,
            change: change
        )
    }

    /// Reconciles a server page against what is already loaded.
    ///
    /// `replacingChangedSuffix` aligns on a common *prefix*, which is right when
    /// both sides start at the same message. A refresh does not: it returns the
    /// most recent turns, while the local copy may hold far more history behind
    /// them. Aligned as prefixes those share nothing, so the transcript would
    /// collapse to the page — and the renderer can only express a shrink as a
    /// full rebuild, which is visible as the whole thread flashing.
    ///
    /// Find where the page begins in what we already have and keep everything
    /// older than it untouched.
    private func mergingHistory(
        _ current: [FeatureMessage],
        with incoming: [FeatureMessage]
    ) -> [FeatureMessage] {
        guard !current.isEmpty, let first = incoming.first else { return incoming }
        guard let overlap = current.firstIndex(where: { $0.id == first.id }), overlap > 0 else {
            return replacingChangedSuffix(current, with: incoming)
        }
        return Array(current[..<overlap])
            + replacingChangedSuffix(Array(current[overlap...]), with: incoming)
    }

    private func replacingChangedSuffix<Element: Equatable>(
        _ current: [Element],
        with incoming: [Element]
    ) -> [Element] {
        guard current != incoming else { return current }
        let prefixCount = zip(current, incoming).prefix { pair in
            pair.0 == pair.1
        }.count
        var result = current
        result.replaceSubrange(prefixCount..., with: incoming.dropFirst(prefixCount))
        return result
    }

    private func restoreOutbox() async {
        let submissions: [FeatureQueuedSubmission]
        do {
            submissions = try await outboxStore.submissions()
        } catch {
            errorMessage = "Could not restore queued messages: \(error.localizedDescription)"
            return
        }

        for submission in submissions {
            setAttachmentOutboxOwnership(true, for: submission)
            if let creation = submission.creation {
                if snapshot.threads.contains(where: { $0.id == submission.threadID }) {
                    pendingSubmissionsByID[submission.id] = submission
                    if let detail = details[submission.threadID] {
                        store(addingPendingMessages(to: detail))
                    }
                    continue
                }
                guard let project = snapshot.projects.first(where: {
                    $0.id == creation.projectID && $0.environmentID == submission.environmentID
                }) else {
                    if isEnvironmentConnected(submission.environmentID) {
                        await discardRestoredSubmission(submission)
                    } else {
                        pendingSubmissionsByID[submission.id] = submission
                    }
                    continue
                }
                pendingSubmissionsByID[submission.id] = submission
                installPendingCreation(submission, project: project)
                continue
            }

            guard snapshot.threads.contains(where: { $0.id == submission.threadID }) else {
                if pendingThreadsByID[submission.threadID] != nil {
                    pendingSubmissionsByID[submission.id] = submission
                } else if isEnvironmentConnected(submission.environmentID) {
                    await discardRestoredSubmission(submission)
                } else {
                    pendingSubmissionsByID[submission.id] = submission
                }
                continue
            }
            pendingSubmissionsByID[submission.id] = submission
            if let detail = details[submission.threadID] {
                store(addingPendingMessages(to: detail))
            }
        }
    }

    private func discardRestoredSubmission(_ submission: FeatureQueuedSubmission) async {
        pendingSubmissionsByID[submission.id] = submission
        await discardQueuedSubmission(submission)
    }

    private func enqueue(_ submission: FeatureQueuedSubmission) async -> Bool {
        do {
            try await outboxStore.enqueue(submission)
            pendingSubmissionsByID[submission.id] = submission
            setAttachmentOutboxOwnership(true, for: submission)
            return true
        } catch {
            errorMessage = "Could not safely queue this message: \(error.localizedDescription)"
            return false
        }
    }

    private func installPendingCreation(
        _ submission: FeatureQueuedSubmission,
        project: FeatureProject
    ) {
        guard let creation = submission.creation else { return }
        let provider = provider(
            id: submission.selection?.providerID,
            environmentID: submission.environmentID
        )
        let environmentName = snapshot.environments.first {
            $0.id == submission.environmentID
        }?.name
        let title = submission.text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = FeatureThread(
            id: submission.threadID,
            wireID: submission.identity.threadID,
            projectID: project.id,
            environmentID: submission.environmentID,
            environmentName: environmentName,
            title: title?.isEmpty == false ? title! : "New task",
            preview: submission.text,
            branch: creation.branch,
            worktreePath: creation.worktreePath,
            createdAt: submission.identity.createdAt,
            updatedAt: submission.identity.createdAt,
            state: .queued,
            providerID: submission.selection?.providerID,
            providerName: provider?.name,
            modelID: submission.selection?.modelID,
            runtimeMode: submission.runtimeMode,
            interactionMode: submission.interactionMode
        )
        pendingThreadsByID[thread.id] = thread
        upsert(thread)
        store(FeatureThreadDetail(
            thread: thread,
            messages: [queuedMessage(for: submission)]
        ))
    }

    private func provider(id: String?, environmentID: String) -> FeatureProvider? {
        guard let id else { return nil }
        let providers = snapshot.providersByEnvironment?[environmentID] ?? []
        return providers.first { $0.id == id }
    }

    private func queuedMessage(for submission: FeatureQueuedSubmission) -> FeatureMessage {
        FeatureMessage(
            id: submission.identity.messageID,
            role: .user,
            text: submission.text,
            createdAt: submission.identity.createdAt,
            state: .queued,
            attachments: submission.attachments.enumerated().map { index, attachment in
                FeatureMessageAttachment(
                    id: "\(submission.id)-attachment-\(index)",
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    sizeBytes: attachment.byteCount ?? attachment.data?.count ?? 0
                )
            }
        )
    }

    private func addingPendingMessages(to incoming: FeatureThreadDetail) -> FeatureThreadDetail {
        let queued = pendingSubmissionsByID.values
            .filter { $0.threadID == incoming.thread.id }
            .sorted { $0.identity.createdAt < $1.identity.createdAt }
        guard !queued.isEmpty else { return incoming }
        var result = incoming
        let existing = Set(result.messages.map(\.id))
        result.messages.append(contentsOf: queued.lazy
            .filter { !existing.contains($0.identity.messageID) }
            .map(queuedMessage(for:)))
        return result
    }

    private func retainingLocalAttachmentPreviews(
        in incoming: FeatureThreadDetail
    ) -> FeatureThreadDetail {
        guard let current = details[incoming.thread.id] else { return incoming }
        let currentMessages = current.messages.reduce(into: [String: FeatureMessage]()) {
            $0[$1.id] = $1
        }
        var result = incoming
        result.messages = incoming.messages.map { message in
            guard let local = currentMessages[message.id], !message.attachments.isEmpty else {
                return message
            }
            var message = message
            message.attachments = message.attachments.enumerated().map { index, attachment in
                guard attachment.previewData == nil else { return attachment }
                let matching = local.attachments.first { candidate in
                    candidate.id == attachment.id
                } ?? (
                    local.attachments.indices.contains(index)
                        ? local.attachments[index]
                        : nil
                )
                guard let previewData = matching?.previewData else { return attachment }
                var attachment = attachment
                attachment.previewData = previewData
                return attachment
            }
            return message
        }
        return result
    }

    private func acknowledgeDeliveredMessages(_ messages: [FeatureMessage]) {
        // Runs on every detail publish; skip the full message-ID scan in the
        // common case where nothing is waiting in the outbox.
        guard !pendingSubmissionsByID.isEmpty else { return }
        // Local optimistic rows reuse the final message ID but are not proof
        // that the server accepted the turn. Only authoritative, non-queued
        // rows can retire a durable outbox entry.
        let messageIDs = Set(messages.lazy
            .filter { $0.state != .queued }
            .map(\.id))
        let delivered = pendingSubmissionsByID.values.filter {
            messageIDs.contains($0.identity.messageID)
        }
        for submission in delivered {
            scheduleQueuedSubmissionCompletion(submission)
        }
    }

    private func scheduleQueuedSubmissionCompletion(_ submission: FeatureQueuedSubmission) {
        guard pendingCompletionSubmissionIDs.insert(submission.id).inserted else { return }
        pendingDiscardSubmissionIDs.remove(submission.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !(await self.completeQueuedSubmission(submission)) {
                self.scheduleOutboxRetry()
            }
        }
    }

    @discardableResult
    private func completeQueuedSubmission(_ submission: FeatureQueuedSubmission) async -> Bool {
        pendingCompletionSubmissionIDs.insert(submission.id)
        pendingDiscardSubmissionIDs.remove(submission.id)
        do {
            try await outboxStore.remove(id: submission.id)
        } catch {
            errorMessage = "The message was delivered, but its queued copy could not be cleared: \(error.localizedDescription)"
            return false
        }
        pendingCompletionSubmissionIDs.remove(submission.id)
        pendingSubmissionsByID.removeValue(forKey: submission.id)
        setAttachmentOutboxOwnership(false, for: submission)
        pendingThreadsByID.removeValue(forKey: submission.threadID)
        markQueuedMessageDelivered(submission)
        outboxRetryAttempt = 0
        return true
    }

    private func markQueuedMessageDelivered(_ submission: FeatureQueuedSubmission) {
        mutateDetail(
            id: submission.threadID,
            change: .delta(FeatureDetailDelta(changedMessages: []))
        ) { detail in
            guard let index = detail.messages.firstIndex(where: {
                $0.id == submission.identity.messageID
            }) else { return }
            detail.messages[index].state = .complete
        }
    }

    @discardableResult
    private func discardQueuedSubmission(_ submission: FeatureQueuedSubmission) async -> Bool {
        pendingCompletionSubmissionIDs.remove(submission.id)
        pendingDiscardSubmissionIDs.insert(submission.id)
        do {
            try await outboxStore.remove(id: submission.id)
        } catch {
            errorMessage = "Could not remove the queued message: \(error.localizedDescription)"
            return false
        }
        pendingDiscardSubmissionIDs.remove(submission.id)
        pendingSubmissionsByID.removeValue(forKey: submission.id)
        setAttachmentOutboxOwnership(false, for: submission)
        let wasPendingCreation = pendingThreadsByID.removeValue(forKey: submission.threadID) != nil
        if wasPendingCreation {
            removeThread(id: submission.threadID)
            removeDetail(id: submission.threadID)
        } else {
            mutateDetail(id: submission.threadID) {
                $0.messages.removeAll { $0.id == submission.identity.messageID }
            }
        }
        return true
    }

    private func setAttachmentOutboxOwnership(
        _ owned: Bool,
        for submission: FeatureQueuedSubmission
    ) {
        if owned {
            attachmentUploads.syncOutboxOwner(
                ownerID: submission.id,
                environmentID: submission.environmentID,
                attachmentIDs: submission.attachments.map(\.id)
            )
        } else {
            attachmentUploads.removeOutboxOwner(ownerID: submission.id)
        }
    }

    private func removePendingSubmissions(environmentID: String) {
        let removed = pendingSubmissionsByID.values.filter {
            $0.environmentID == environmentID
        }
        for submission in removed {
            pendingCompletionSubmissionIDs.remove(submission.id)
            pendingDiscardSubmissionIDs.remove(submission.id)
            pendingSubmissionsByID.removeValue(forKey: submission.id)
            setAttachmentOutboxOwnership(false, for: submission)
            if pendingThreadsByID.removeValue(forKey: submission.threadID) != nil {
                removeThread(id: submission.threadID)
                removeDetail(id: submission.threadID)
            } else {
                mutateDetail(id: submission.threadID) {
                    $0.messages.removeAll { $0.id == submission.identity.messageID }
                }
            }
        }
    }

    private func markPendingSubmissionsForDiscard(environmentID: String) {
        for submission in pendingSubmissionsByID.values where submission.environmentID == environmentID {
            pendingCompletionSubmissionIDs.remove(submission.id)
            pendingDiscardSubmissionIDs.insert(submission.id)
        }
    }

    private func scheduleOutboxDrain(after delay: Duration = .zero) {
        guard outboxDrainTask == nil, !pendingSubmissionsByID.isEmpty else { return }
        let generation = outboxGeneration
        outboxDrainTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled,
                  let self,
                  self.outboxGeneration == generation else { return }
            let needsRetry = await self.drainOutbox(generation: generation)
            self.outboxDrainTask = nil
            if needsRetry,
               !Task.isCancelled,
               self.outboxGeneration == generation {
                self.scheduleOutboxRetry()
            }
        }
    }

    private func stopOutboxDrain() async {
        outboxGeneration &+= 1
        guard let task = outboxDrainTask else { return }
        task.cancel()
        await task.value
        outboxDrainTask = nil
    }

    private func scheduleOutboxRetry() {
        guard outboxDrainTask == nil else { return }
        let seconds = min(16, 1 << min(outboxRetryAttempt, 4))
        outboxRetryAttempt += 1
        scheduleOutboxDrain(after: .seconds(seconds))
    }

    private func drainOutbox(generation: UInt64) async -> Bool {
        let submissions = pendingSubmissionsByID.values.sorted {
            $0.identity.createdAt < $1.identity.createdAt
        }
        var needsRetry = false
        for submission in submissions where pendingSubmissionsByID[submission.id] != nil {
            guard !Task.isCancelled, outboxGeneration == generation else { return false }
            if pendingCompletionSubmissionIDs.contains(submission.id) {
                if !(await completeQueuedSubmission(submission)) {
                    needsRetry = true
                }
                continue
            }
            if pendingDiscardSubmissionIDs.contains(submission.id) {
                if !(await discardQueuedSubmission(submission)) {
                    needsRetry = true
                }
                continue
            }
            var policySnapshot = snapshot
            if pendingThreadsByID[submission.threadID] != nil {
                policySnapshot.threads.removeAll { $0.id == submission.threadID }
            }
            switch FeatureOutboxPolicy.decision(
                for: submission,
                snapshot: policySnapshot,
                pendingCreationThreadIDs: Set(
                    pendingSubmissionsByID.values.compactMap {
                        $0.creation == nil ? nil : $0.threadID
                    }
                )
            ) {
            case .discard:
                if !(await discardQueuedSubmission(submission)) {
                    needsRetry = true
                }
            case .wait:
                // Connectivity and snapshot events wake the drain immediately.
                // Avoid a permanent timer while the owning device is offline.
                continue
            case .send:
                do {
                    guard pendingSubmissionsByID[submission.id] != nil,
                          snapshot.environments.contains(where: {
                              $0.id == submission.environmentID
                          }) else {
                        continue
                    }
                    if let creation = submission.creation {
                        let thread = try await client.createThreadAndSend(
                            projectID: creation.projectID,
                            prompt: submission.text,
                            selection: submission.selection,
                            runtimeMode: submission.runtimeMode,
                            interactionMode: submission.interactionMode,
                            workspaceMode: creation.workspaceMode,
                            branch: creation.branch,
                            worktreePath: creation.worktreePath,
                            startFromOrigin: creation.startFromOrigin,
                            attachments: submission.uploads,
                            identity: submission.identity
                        )
                        guard !Task.isCancelled,
                              outboxGeneration == generation else { return false }
                        if !(await completeQueuedSubmission(submission)) {
                            needsRetry = true
                        }
                        if thread.id != submission.threadID {
                            removeThread(id: submission.threadID)
                            removeDetail(id: submission.threadID)
                        }
                        upsert(thread)
                    } else {
                        try await client.sendMessage(
                            threadID: submission.threadID,
                            text: submission.text,
                            selection: submission.selection,
                            runtimeMode: submission.runtimeMode,
                            attachments: submission.uploads,
                            identity: submission.identity
                        )
                        guard !Task.isCancelled,
                              outboxGeneration == generation else { return false }
                        if !(await completeQueuedSubmission(submission)) {
                            needsRetry = true
                        }
                    }
                } catch {
                    if Self.shouldQueue(
                        error,
                        environmentID: submission.environmentID,
                        snapshot: snapshot
                    ) {
                        needsRetry = true
                    } else {
                        if !(await discardQueuedSubmission(submission)) {
                            needsRetry = true
                        } else {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
        return needsRetry
    }

    private func isEnvironmentConnected(_ environmentID: String) -> Bool {
        guard let environment = snapshot.environments.first(where: { $0.id == environmentID }) else {
            return false
        }
        return environment.isEnabled && environment.connectionState == .connected
    }

    static func shouldQueue(
        _ error: any Error,
        environmentID: String,
        snapshot: FeatureSnapshot
    ) -> Bool {
        if error is CancellationError || error is URLError { return true }
        if let rpcError = error as? RPCError,
           case .responseTimedOut = rpcError {
            return true
        }
        if let environment = snapshot.environments.first(where: { $0.id == environmentID }) {
            let disconnected = !environment.isEnabled
                || environment.connectionState != .connected
            if disconnected { return true }
        }
        let message = error.localizedDescription.lowercased()
        return [
            "cancelled", "canceled", "connection", "network", "offline",
            "socket", "timed out", "timeout", "transport", "not connected",
            "request deadline",
        ].contains { message.contains($0) }
    }
}

private extension FeatureDraftAttachment {
    var upload: FeatureUploadAttachment {
        FeatureUploadAttachment(self)
    }
}
