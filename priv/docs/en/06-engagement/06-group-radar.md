%{
  title: "Group radar",
  description: "Who needs attention and why: statuses, reasons and recommendations."
}
---
## Purpose

The :ui[Group Radar] answers the question "who in the group needs the teacher's attention right now, and why". Each student gets one **status** by explicit rules, and the signals that led to it are listed next to it.

## How to open

1. :ui[Teaching] › :ui[Cohorts] › the group.
2. In the :ui[Assigned Courses] table, click :ui[Engagement] in the course's row.
3. At the top of the screen, select the :ui[Group Radar] tab.

For teams the path is the same, via :ui[Teaching] › :ui[Teams].

## Screen elements

### Period

To the right of the heading is the period selector: :ui[Last 7 days] (default), :ui[Last 30 days] or :ui[Whole course]. The selected period is repeated under the heading.

The period affects signals: only events and tasks submitted within it are considered. Course progress and the :ui[Avg score] column always cover the whole course. Changing the period recalculates the screen; opening a card or filtering by status does not.

### Status tiles

Under the heading are seven tiles, one per status, with the number of students in it. The tiles also act as a filter:

- clicking a tile leaves only students with that status in the table;
- clicking the same tile again removes the filter;
- if nobody is left in the filtered table, click :ui[Show everyone].

Tiles with no students are shown faded.

### Explanation line and methodology window

Under the tiles is a line with the short rule for deciding a status and the :ui[How is this decided?] button. The button opens the :ui[How a student's status is decided] window: the rules in order, a :ui[How we compare] part (what the values are compared with) and a :ui[What the system can't see] part. The window is closed with :ui[Got it].

### Table

| Column | Contents |
|---|---|
| :ui[Student] | The student's name; clicking it opens the card |
| :ui[Status] | The student's status |
| :ui[Why] | Up to three reason chips; the rest are folded into a "+N more" counter. A chip shows the short signal name and, if the signal fired several times, how many. All assessment violations are merged into the :ui[Exam violations] chip |
| :ui[Progress] | Share of the course's blocks completed, whole course |
| :ui[Avg score] | Average best score over all graded tasks of the course, whole course |

Clicking anywhere in a row opens the student card.

### Student card

The card opens on the right over the table. Close it with the cross, by clicking outside it, or with Esc. The open card is kept in the page address, so a link to it can be shared with a colleague.

Contents of the card, top to bottom:

1. **Header**: name, status, the status's condition, and lines on the share of opened blocks with rushing and with difficulties compared with the group's usual share, for example "Rushing on 30% of opened blocks (12); usually 8% in this group". A line is highlighted if the share is enough for the status.
2. **Figures**: :ui[Progress] and :ui[Avg score] next to the group's median of these figures, and the number of :ui[Signals].
3. **:ui[What you can do]**: up to four recommendations (see below).
4. **:ui[What counted]**: every signal that fired, grouped by category. For each signal the block, the value and what it was compared with are given. The :ui[Open] link next to a signal opens that block on the :ui[Course Radar] in this student's lens. For a low score or many attempts, the theory blocks before the task are listed below with how they were studied.
5. **Buttons**: :ui[Open in course radar] – the course map through this student's eyes; :ui[Scores in gradebook] – the gradebook filtered to this student (requires the `grading.read` permission).

If nothing fired during the period, :ui[What counted] reads ":ui[Nothing worth worrying about in this period.]".

## Status rules

A student is checked against the rules from top to bottom; **the first rule that matches sets the status**. So a student with an assessment violation and low scores gets :ui[Integrity risk], and the low scores stay in the card's list of signals.

| # | Status | Rule (default values) |
|---|---|---|
| 1 | :ui[Not engaging] | The :ui[No activity] signal fired: no events in the period while the group was active |
| 2 | :ui[Integrity risk] | At least 1 signal of the :ui[Integrity] category |
| 3 | :ui[Not mastering the material] | At least 2 :ui[Low score] signals, **or** at least 2 unresolved :ui[Many attempts] signals (best attempt below 50) |
| 4 | :ui[Falling behind] | The :ui[Behind the group] signal fired, **or** at least 5 blocks completed by most of the group were skipped, and they make up at least 10% of all such blocks |
| 5 | :ui[Skimming] | Rushing is a consistent pattern (see below) |
| 6 | :ui[Struggling] | Difficulties are a consistent pattern (see below) |
| 7 | :ui[On track] | None of the rules above matched |

Threshold values are configurable, see [Thresholds reference](/docs/engagement/thresholds). Signal definitions are in the [Signals reference](/docs/engagement/signals).

### Rushing and difficulty patterns

One block gone through too fast does not change the status. :ui[Skimming] (and likewise :ui[Struggling]) is assigned only when **all three** conditions hold:

1. There are **at least 3** blocks with at least one signal of the :ui[Rushing] (respectively :ui[Difficulties]) category.
2. These blocks make up **at least 25%** of the blocks the student opened during the period.
3. This share is **at least twice** the group's median of the same share. The median is taken over students who opened anything, if there are at least 5 of them; otherwise this condition is not checked.

Shares rather than absolute counts are used so that a 400-block course and a 20-block course are judged alike, and the group comparison keeps features of the material (say, long videos everybody skips) from making everyone "skimming".

### Skipped blocks

A block counts as "completed by most" if at least 60% of the group's students completed it. Let there be *N* such blocks in the course, of which the student has not completed *k*. Rule 4 requires *k* ≥ 5 and *k* / *N* ≥ 0.1.

## Recommendations

:ui[What you can do] is built from the signals that fired, in a fixed order; the first four applicable recommendations are shown:

| Condition | Recommendation |
|---|---|
| :ui[No activity] | :ui[Reach out personally: they haven't opened the course during this period.] |
| Any :ui[Integrity] signal | :ui[Review the flagged exam attempt in the cheating monitor before grading it.] |
| :ui[Low score], theory before the task skipped or skimmed | Ask them to go back to that theory (up to two blocks are named) |
| :ui[Low score], theory studied normally | Go through the task together: the topic itself may be unclear |
| :ui[Many attempts] | Look at the attempts on the task: many quick retries usually mean guessing |
| :ui[Skipped blocks] | Remind them about the skipped blocks (up to three are named) |
| :ui[Behind the group] with no skipped blocks | :ui[Check in on their pace: they are well behind the group in the course.] |
| Any :ui[Rushing] signal | :ui[Talk about pace: they go through the material much faster than the group.] |
| Any :ui[Difficulties] signal | Offer help with the block where the signal fired first |

## Worked example

A group of 19 students, period :ui[Last 7 days]. In the table a student has the status :ui[Not mastering the material] and the chips :ui[Low score] ×2 and :ui[Too fast] ×3.

1. Open the card. Under :ui[What counted], the :ui[Results] category holds two low scores: 35 and 40, with group medians of 78 and 82. So the group passed these tasks, and the problem is individual.
2. Under each low score the theory before the task is listed. If it says ":ui[skimmed]" or ":ui[never opened]", the likely cause is skipped theory; the recommendation will suggest going back to specific blocks.
3. The :ui[Too fast] ×3 chips do not set the status on their own: in the card header the rushing line is not highlighted, because 3 blocks of 40 opened is less than 25%.
4. Click :ui[Open] next to a low score to see the task on the :ui[Course Radar], or :ui[Scores in gradebook] to open the student's answers.

> [!TIP]
> A status is a reason to look closer, not a judgement of the student. Check the signals in the card before talking to the student: the system cannot see study outside the platform or reasons for absence.
