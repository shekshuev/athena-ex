%{
  title: "Settings and nudges",
  description: "Expected block time, nudges to students and how to enable them."
}
---
## Engagement settings

Every section and every block of a course has three optional settings. They are set in the course builder, in the :ui[Engagement Tracking] panel of the inspector:

1. Open :ui[Studio] › :ui[Course Manager] and go to the builder of the course.
2. Select a section or a block. The inspector opens on the right.
3. Fill in the fields of the :ui[Engagement Tracking] panel.

The :ui[Engagement Tracking] panel is only visible to users with the `engagement.update` permission.

| Field | Meaning | Used by |
|---|---|---|
| :ui[Expected time to complete (seconds)] | How many seconds the author expects the block to take | The :ui[Too fast] and :ui[Very slow] signals; the :ui[Time vs. planned] metric; the fallback rule of the fast-completion nudge |
| :ui[Fast-completion threshold (0-1)] | Which share of the expected time counts as "too fast" for a nudge | The fast-completion nudge only |
| :ui[Allow nudges in this section?] / :ui[Allow nudges on this block?] | Whether nudges are allowed | Every nudge |

### Inheritance

Each field is resolved separately, by the first value set along the chain:

1. the block's value;
2. the value of the section the block is in;
3. the application default (see [Thresholds reference](/docs/engagement/thresholds)).

An empty field and the :ui[Inherit] option mean "take the value from the level above". For allowing nudges, an explicit :ui[Disabled] on a block forbids nudges on that block even if its section allows them. If nudges are not configured anywhere, they are allowed.

By default no block has an expected time, and the fast-completion threshold is 0.4.

> [!TIP]
> Set an expected time for blocks where the author has a clear idea of the right pace, such as short videos or tasks. Without an expected time, time on the block is compared with the group's median, which is more accurate for most blocks.

## Nudges to students

A nudge is a short pop-up message in the course player that a student sees when going through the material noticeably more superficially than usual. A nudge does not block progress and does not affect grades.

### When a nudge is shown

A nudge is shown only if all of the following hold:

- nudges are enabled for the student's group;
- nudges are allowed for the block (with inheritance);
- a nudge with the same reason has not been shown on this block in the current session.

> [!WARNING]
> In the current version, enabling nudges for a group is not available in the interface: nudges are off by default for every group and team. A system administrator can enable them.

### Nudge reasons

| Reason | Condition | Text the student sees |
|---|---|---|
| Fast completion | See below | ":ui[You went through that pretty fast - want to go back and double-check?]" |
| Text not read | A text block was left while the largest visible share of its height was below 70% | ":ui[Looks like you scrolled past without reading much - want to go back?]" |
| Ready-made answer pasted | A single paste made up more than 80% of the answer's characters (open-answer question or code task) | ":ui[Looks like you pasted a ready-made answer - are you sure you understand it?]" |
| Video skipped | The video was watched to the end, but forward seeks added up to more than 30% of its duration | ":ui[You skipped through most of that video - sure you got it all?]" |

If the "text not read" nudge fired when a text block was left, the fast-completion nudge is no longer shown on that block.

### Fast completion

The decision is made when the block leaves the screen, from the time of that last view:

1. If the group has **at least 15 measurements** of time on this block, the view time is compared with the group's distribution. A nudge is shown if it falls into the **bottom 10%**.
2. With fewer measurements, but with an expected time set for the block, a nudge is shown if the time is below `expected time × fast-completion threshold`. For example, with an expected time of 300 s and a threshold of 0.4, below 120 s.
3. With neither enough measurements nor an expected time, no nudge is shown.

The block's time distribution is visible in the block detail on the :ui[Course Radar] screen (the :ui[Dwell distribution] chart; the bottom 10% is highlighted in red).

> [!NOTE]
> This decision uses view time without idle subtraction, because it is made immediately, before idle events are processed.

### Measuring whether nudges help

On the :ui[Course Radar] screen, on the :ui[Activity] tab, the :ui[Nudge correction rate] chart shows for each reason which share of nudges did not repeat: after the nudge, the same signal never fired again for the same student on any block of the course. See [Course radar](/docs/engagement/course-radar).
