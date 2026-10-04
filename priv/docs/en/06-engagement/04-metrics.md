%{
  title: "Metrics reference",
  description: "Definitions and formulas of every block metric."
}
---
## How metrics are computed

A student's events on one block during one calendar day are folded into a set of **counts and sums** (number of entries, total time, number of pastes and so on). Counts add up without loss: a student's week is the sum of their seven days, a group's figure for a block is the sum of its students. Every metric is derived from these sums by one formula, wherever it is shown.

Metrics are shown in the block detail on the :ui[Course Radar] screen (the grid of values above the :ui[Weekly trend] chart). Depending on the :ui[Looking at] lens, values refer to the whole group or to one student. Block detail always covers the whole history of the course, not the selected period.

Terms used in the formulas:

- a *visit* is one "block enters the viewport – block leaves the viewport" pair within one session;
- a *session* is one opening of the player or assessment page;
- *observed students* are students with at least one event on the block.

When a metric cannot be computed (for example, there are no visits), "–" is shown.

## Common metrics

Computed for every block type.

| Metric | Definition and formula |
|---|---|
| :ui[Visits measured] | Number of visits |
| :ui[Average time, s] | Total time of all visits (idle subtracted) / number of visits |
| :ui[Time vs. planned] | :ui[Average time, s] / the block's expected time. Shown only when an expected time is set |
| :ui[Students] | Number of observed students |
| :ui[Tab switches] | Number of times the tab was hidden while the block was on screen |
| :ui[Time to first action, s] | Average per session of the time from the block entering the viewport to the first action on it |
| :ui[Share of time in other tabs] | Total time with the tab hidden / total time on screen without idle subtraction; at most 1 |
| :ui[Came back after moving on] | Number of returns: within one session and one day the student came back to the block after opening a later block of the same section. At most one return to a block is counted per student per session |
| :ui[Share who came back] | :ui[Came back after moving on] / number of observed students |
| :ui[Share who changed answers] | Share of observed students who changed an answer at least once |

## Metrics by block type

### Text

| Metric | Definition and formula |
|---|---|
| :ui[Scrolled, %] | Average per session of the highest visibility mark (0, 25, 50, 75 or 100%). See the limitation for long texts in [Data collection](/docs/engagement/data-collection) |

### Video

| Metric | Definition and formula |
|---|---|
| :ui[Plays] | Number of plays |
| :ui[Pauses] | Number of pauses |
| :ui[Rewinds] | Number of seeks in either direction |
| :ui[Watched to the end] | Number of times watched to the end |
| :ui[Share skipped] | Average over sessions in which the video was watched to the end: total forward seeks in seconds / video duration. Sessions without reaching the end are not counted, since their duration is unknown |

### Question

| Metric | Definition and formula |
|---|---|
| :ui[Share pasted] | Average over all pastes: pasted characters / total characters in the answer at the time of the paste |
| :ui[Answer changes] | Number of answer changes after the first pick |

### Code task

| Metric | Definition and formula |
|---|---|
| :ui[Share pasted] | As for a question |
| :ui[Code runs] | Number of times the run button was pressed |
| :ui[Ran the code] | "Yes" if the code was run at least once |
| :ui[Rapid re-runs] | "Yes" if at least three times the gap between consecutive runs (within one day) was under 10 seconds |

### Attachment

| Metric | Definition and formula |
|---|---|
| :ui[Opens] | Number of times the file was opened |
| :ui[Students who opened] | Number of students who opened the file at least once |

### Image

| Metric | Definition and formula |
|---|---|
| :ui[Zooms] | Number of image zooms |

### Assessment and ticket assessment

| Metric | Definition and formula |
|---|---|
| :ui[Left the exam tab] | Number of times the tab was hidden during the attempt |
| :ui[Time away from the exam, s] | Total time with the tab hidden |
| :ui[Window lost focus] | Number of window focus losses |
| :ui[Screenshot attempts] | Number of PrintScreen presses |
| :ui[Copy attempts] | Number of attempts to copy the question text |
| :ui[Cut attempts] | Number of attempts to cut the question text |
| :ui[Opened in several tabs] | Number of times the same attempt was detected in another tab |
| :ui[Idle time, s] | Total idle time |
| :ui[Share pasted] | As for a question, over assessment answer fields |
| :ui[Answer changes] | Number of answer changes across all questions |
| :ui[Code runs] | Number of code runs inside the assessment |
| :ui[Rapid re-runs] | As for a code task |

These metrics describe behaviour on the engagement screens. The risk of a particular attempt is decided by a separate procedure with different rules, see [Academic integrity](/docs/grading/academic-integrity).

## Group figures

When a metric is computed for a group, the counts and sums of all its students are added up and then the same formula is applied. So, for example, a group's :ui[Average time, s] is the average over **all visits** of all students, not an average of per-student averages. A student who visited a block many times weighs more in it.

Comparing a student with the group uses different values – medians and percentiles across students, see [Signals reference](/docs/engagement/signals).
