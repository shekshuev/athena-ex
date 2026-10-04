%{
  title: "Data collection",
  description: "Which actions are recorded, when, and with which limitations."
}
---
## Principle

Every number in the module comes from **events**: short records of the form "who did what, on which block, when". An event carries no interpretation. All conclusions (time on a block, signals, statuses) are computed later from events by a single set of formulas (see [Metrics reference](/docs/engagement/metrics)).

Events are sent by the student's browser:

- in the **course player**, while going through sections;
- on **assessment** and **ticket assessment** pages, during an attempt.

The browser queues events and sends them in a batch every 10 seconds, and when the page is left. The server attaches the account, group and session itself; a browser cannot report events on someone else's behalf.

Every event is tied to the group (or team) in which the student takes the course. Events without a group, for example from self-paced study, are stored but do not appear on the engagement screens.

## Event catalogue

### All blocks

| Event | When it happens |
|---|---|
| Block enters and leaves the viewport | The block appeared on screen and left it. An enter–leave pair gives time on the block |
| Tab hidden and shown | The browser tab lost and regained visibility |
| Window blur and focus | The browser window lost and regained focus (for example, switching to another application) |
| Idle start and end | 2 minutes with no mouse movement, key presses or scrolling, then activity resumes. Idle time is subtracted from time on the block |
| First action | The first meaningful action on a block: the first key press in a code editor or the first answer picked |
| Nudge shown | A nudge was shown to the student (recorded by the server, not the browser) |

### By block type

| Block type | Events |
|---|---|
| Text | Marks 25, 50, 75 and 100%: how much of the block's height was on screen at once |
| Video | Play, pause, seek (with "from" and "to" positions), speed change, watched to the end |
| Image | Image zoom |
| Attachment | File opened |
| Question | First answer picked, every later answer change, paste into an open answer field |
| Code task | Paste into the editor, code run (recorded by the server when the button is pressed) and its result |

For a paste only **character counts** are recorded (pasted and total in the answer), never the text itself.

### During assessments only

| Event | When it happens |
|---|---|
| Screenshot attempt | The PrintScreen key was pressed (Windows only) |
| Copy or cut attempt | An attempt to copy or cut the question text; the action itself is blocked |
| Right click | A right click on the question text |
| Several tabs | The same attempt is open in another tab of the same browser |
| Insert without typing | A large piece of text appeared in an answer field without typing, paste or drag-and-drop |
| Typing summary | Aggregate typing characteristics (no keys and no per-keystroke timestamps) |
| Offline period | The browser reported being offline, and for how long |
| Pointer outside the window | The mouse pointer left the browser window, and for how long |
| Window size change | The window stopped filling the screen (for example, split with another window) or went back |
| Fullscreen exit | Only for assessments that require fullscreen |

How these events turn into a risk rating is described in [Academic integrity](/docs/grading/academic-integrity).

## Time and calendar days

Event times are stored in UTC and converted to the application time zone for counting. Every period on the engagement screens is made of **whole calendar days** in that zone:

- "last 7 days" means today and the six previous full days;
- a day starts at midnight in the application time zone, not the student's.

A session running past midnight is counted as two sessions, one per day.

## Idle subtraction

Time on a block is the time between the block entering and leaving the viewport, minus idle time, that is the time from the moment 2 minutes of inactivity have passed until activity resumes.

Time with the tab hidden is not subtracted separately; it is a metric of its own (share of time in other tabs). If a student stays in another tab for long, idle starts after 2 minutes, and the rest of that time is subtracted from time on the block.

> [!NOTE]
> The first 2 minutes of inactivity are not idle: the system cannot tell them apart from careful reading. A page left open therefore still adds up to 2 minutes to time on the block.

## How reading of text is measured

For a text block the browser records **how much of the block's height is visible on screen at once**: 25, 50, 75 or 100%. This is not a scroll position. A block that fits on screen gets 100% immediately. A block taller than the screen cannot get a mark above the share that fits on screen at once, even if it was read to the end.

> [!WARNING]
> For long text blocks (noticeably taller than the browser window) the :ui[Scrolled, %] metric and the :ui[Doesn't read to the end] signal systematically understate reading. Such blocks are better split into several short ones.

## What the system does not record

- The content of answers and pasted text (only character counts).
- Which keys were pressed.
- Anything outside the browser: a second device, paper notes, a textbook, help from another person.
- Screenshots taken with macOS or third-party tools.
- Reasons for behaviour: illness, a busy week and loss of interest look the same.

More on limitations in [Interpretation and limitations](/docs/engagement/interpretation).
