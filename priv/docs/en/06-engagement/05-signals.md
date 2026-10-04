%{
  title: "Signals reference",
  description: "The rule behind each signal and how it is compared with the group."
}
---
## What a signal is

A **signal** is an explicitly named observation about a student that fires by a fixed rule: "went through a block too fast", "low score on a task", "opened nothing during the period". Each signal carries the value it fired with and what it was compared against. There are no hidden weights: a student's status on the :ui[Group Radar] screen depends only on how many and which signals fired (see [Group radar](/docs/engagement/group-radar)).

Signals fall into categories. The category name is shown in the student card, the short signal name in the chips of the :ui[Why] column.

| Category | Label | Source |
|---|---|---|
| Activity | :ui[Activity] | Whether there were any events in the period |
| Integrity | :ui[Integrity] | Behaviour during assessments |
| Results | :ui[Results] | Scores and attempts on graded tasks |
| Progress | :ui[Progress] | Completed blocks of the course |
| Rushing | :ui[Rushing] | Behaviour on blocks |
| Difficulties | :ui[Difficulties] | Behaviour on blocks |

## Comparing with the group

Many signals compare a student not with a fixed number but with their group on the same block over the same period. Two baselines are used:

- **median time on the block**: for each student with visits to the block, take their average time; the median of these values is the group's usual time;
- **80th percentile of answer changes**: for each student with events on the block, take their number of answer changes; the 80th percentile is the value that 80% of the group does not exceed.

A baseline is computed only when **at least 5 students** have data (`min_group_for_baseline`). With fewer, there is no group comparison and only fixed thresholds apply, so two or three people never define what is normal.

Medians and percentiles are used instead of averages because time and answer changes are heavily skewed: one student who left a page open for an hour must not shift the whole group's norm.

## Behaviour signals on blocks

Computed for each student on each block they opened during the period.

### Rushing

| Signal | Chip | Rule |
|---|---|---|
| Too fast | :ui[Too fast] | If the block has an expected time: the student's average time < 0.5 × expected. Otherwise, with a group baseline: average time < 0.4 × group median |
| Not read to the end | :ui[Doesn't read to the end] | Text block: :ui[Scrolled, %] < 70 |
| Pastes answers | :ui[Pastes answers] | Question or code task: :ui[Share pasted] > 0.8 |
| Skips video | :ui[Skips video] | Video: :ui[Share skipped] > 0.3 |
| Doesn't run code | :ui[Doesn't run code] | Code task: the code was never run, and :ui[Share pasted] > 0.5 |

> [!NOTE]
> The "too fast" threshold of the signal (0.5 of the expected time) differs from the fast-completion threshold of the nudge (0.4 by default). These are different decisions: a signal for the teacher and an immediate nudge for the student.

### Difficulties

| Signal | Chip | Rule |
|---|---|---|
| Very slow | :ui[Very slow] | With an expected time: average time > 2 × expected. Otherwise, with a group baseline: average time > 2.5 × group median |
| Changes answers | :ui[Changes answers] | At least 2 answer changes and more than the group's 80th percentile. Without a group baseline – at least 3 changes |
| Re-runs code | :ui[Re-runs code] | The :ui[Rapid re-runs] metric is "Yes" |

Coming back to material already covered is not a student signal: it usually indicates self-monitoring, not a problem. Returns are only considered at block level (see below).

### Integrity

Fire on assessment blocks only.

| Signal | Rule |
|---|---|
| Screenshot attempt | :ui[Screenshot attempts] > 0 |
| Copy attempt | :ui[Copy attempts] > 0 |
| Cut attempt | :ui[Cut attempts] > 0 |
| Several tabs | :ui[Opened in several tabs] > 0 |
| Frequently leaving the page | :ui[Left the exam tab] ≥ 3 |
| Pasted answers | :ui[Share pasted] in the assessment > 0.6 |

In the :ui[Why] column all signals of this category are merged into one :ui[Exam violations] chip.

These are simplified absolute rules for the engagement screens. The risk indicator of a particular attempt, which the teacher acts on when grading, is computed differently – with points and comparison with others taking the same assessment (see [Academic integrity](/docs/grading/academic-integrity)).

## Results signals

Graded tasks whose best attempt was submitted within the period are considered.

| Signal | Chip | Rule |
|---|---|---|
| Low score | :ui[Low score] | Score < 50, **and** the group's median on the task is at least 50 (or there is no group baseline). Or the score is 30 or more below the group's median |
| Many attempts | :ui[Many attempts] | With a group baseline: at least 3 attempts and at least 2 × the group median. Without one: more than 3 attempts |

Per-task medians are computed when at least 5 students have scores (or attempts).

The condition "the group's median is at least 50" means: if most of the group fails a task, that is a problem with the task, not the student. Such a task shows up on the course map as a problem spot.

A :ui[Many attempts] signal is additionally marked **unresolved** if the best attempt stayed below 50. Many attempts that ended in a pass are persistence and do not affect the status.

### Theory before a task

Results signals carry a note on how the student went through the **theory before the task**. The course has no explicit "theory – task" link, so it is inferred from position:

- a task's theory is the non-graded blocks (text, video, image, attachment) in the same section between the previous graded block and the task;
- if the task has no such blocks in front of it in its section (the section opens with a task), all non-graded blocks of the previous section are used.

Each theory block gets one of three ratings, over the whole history of the course (the material may have been read long before the task):

| Rating | Condition |
|---|---|
| :ui[studied normally] | The block was opened, and none of :ui[Too fast], :ui[Doesn't read to the end], :ui[Skips video] fired on it |
| :ui[skimmed] | The block was opened, but at least one of these signals fired |
| :ui[never opened] | No events on the block |

## Progress signals

Progress is a whole-course fact and does not depend on the selected period. Progress signals are computed only when the group has at least 5 students.

| Signal | Chip | Rule |
|---|---|---|
| Skipped block | :ui[Skipped blocks] | At least 60% of the group completed the block, but the student did not. Fires separately for each such block |
| Behind | :ui[Behind the group] | Course progress is 20 or more points below the group's median progress |

**Course progress** is the share of the course's blocks marked as completed, in percent. For a team, the team's shared progress is used.

## Activity signal

| Signal | Chip | Rule |
|---|---|---|
| No activity | :ui[No activity] | The student has no events in the course during the period, while someone in the group does |

If nobody in the group was active during the period (for example, a holiday), the signal fires for nobody.

## Block signals

These rules describe a block for the whole group, not an individual student. They are used on the course map.

| Signal | Rule |
|---|---|
| :ui[Students come back] | :ui[Share who came back] > 0.4 |
| :ui[Answers keep changing] | :ui[Share who changed answers] > 0.4 |

The remaining problem spots of the course map are described in [Course radar](/docs/engagement/course-radar).
