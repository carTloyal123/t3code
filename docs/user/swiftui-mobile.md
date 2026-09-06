# SwiftUI mobile

The native SwiftUI app connects to one or more T3 Code computers. Each server owns the settled
state of its threads and its automatic settlement settings. Change those settings per connection
by opening the environment's connection details.

Use **Refresh models** in the model picker for a new or existing task to reload models for the
selected computer. Other connected computers are not refreshed.

## Thread status

Opening a thread shows what the app is waiting on. **Connecting to <computer>** means the app
is still reaching that computer, **Loading messages** means it is fetching the conversation, and
**Up to date** appears briefly once the thread has caught up. **Computer offline** and **Could not
update thread** both offer a **Retry** action.

Connection is reported before loading, so a slow or unreachable computer names itself instead of
looking like a slow thread.

## Following a conversation

Threads are kept on the device, so opening one shows its conversation straight away rather than
waiting on your computer. The app keeps them up to date in the background from the moment it
launches, and fills in older history as it goes, so scrolling back is usually instant.

Once a thread settles, only its most recent turns stay on the device; scrolling further back
fetches the rest again. **Settings → Workspace → History** shows how much space conversations are
using and can clear them. Clearing only removes the copy on your device — nothing is lost, and
threads download again the next time you open them.

The transcript never scrolls on its own. Replies are added as they arrive and your place stays
where you left it — scroll down when you want to read them.

Scrolling back loads earlier turns automatically as you reach them, without moving your place.

## Attachments and sharing

One message can contain up to eight photos, videos, or files. Images can be up to 10 MB. Other
files can be up to 50 MB, or the lower limit reported by the connected server. Older servers accept
images only.

Attachments start uploading while you compose. If an upload fails, the draft keeps its local copy
so you can retry or remove it. Tap an image, PDF, video, or other file to preview it with native
controls when iOS supports that format.

You can share text, links, photos, videos, and files from another app into T3 Code. Choose a project
to add the shared content to a new-task draft. The share extension never sends the draft.

## Voice input

On supported devices with iOS 26 or later, the composer can transcribe up to five minutes of audio
on the device. Voice input needs microphone permission. The first use can also require Apple's
speech model download.

Tap the checkmark to confirm the recording. T3 Code inserts editable text into the draft and never
sends it automatically.

## Codex content

Codex file citations open the cited file when available. Artifact templates include a
**Use** action. **Use** inserts an editable prompt into the composer. Review or change it before
you send it.
