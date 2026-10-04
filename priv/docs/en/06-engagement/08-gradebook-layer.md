%{
  title: "Gradebook: scores and engagement",
  description: "How the gradebook links a task result with how the theory was studied."
}
---
## Purpose

The gradebook shows each student's best score on each graded task of the course. :ui[Scores + engagement] mode adds an answer to the question "how did the student go through the theory before this task". This tells "did not understand the topic" apart from "did not read the material".

Working with the gradebook in the regular mode is described in [Gradebook](/docs/grading/gradebook).

## How to turn it on

1. Open the gradebook: :ui[Teaching] › :ui[Cohorts] › the group › the :ui[Gradebook] button in the course's row (or the :ui[Gradebook] tab on the engagement screens).
2. Above the table, in the mode switch, click :ui[Scores + engagement].

While data loads, ":ui[Loading engagement…]" is shown next to it. Data is loaded once per page visit.

The mode is available when both conditions hold:

- the user has the `engagement.read` permission;
- the gradebook is open for a group. For teams the mode is not shown: a team's progress and solutions are shared.

## Period

:ui[Scores + engagement] mode always covers **the whole course**. This differs from the :ui[Group Radar] and :ui[Course Radar] screens, which default to the last 7 days: the theory may have been studied long before the task, and a short period would distort the picture. So a student's status in the gradebook filter can differ from their status on the :ui[Group Radar] with :ui[Last 7 days]; it matches the status with :ui[Whole course].

## Cell markers

In :ui[Scores + engagement] mode, cells with a score get markers:

| Marker | Position | Meaning |
|---|---|---|
| Yellow dot | Top right corner | :ui[Theory before the task skipped or skimmed]: the student never opened, or skimmed, at least one theory block before the task |
| Diamond | Top left corner | :ui[Flagged by the cheating monitor]: yellow – the cheating monitor noticed some violations; red – high risk or a violation confirmed by the teacher |

The diamond reflects the verdict on the attempt shown. The teacher's decision wins over the automatic rating: after :ui[Reviewed - no violation] the diamond disappears, after :ui[Confirm violation] it turns red. See [Academic integrity](/docs/grading/academic-integrity).

How the theory before a task is determined and rated is described in the [Signals reference](/docs/engagement/signals#theory-before-a-task).

## Theory columns

The :ui[Show theory columns] switch adds columns for the theory blocks, in front of each task. Each cell holds an icon for the rating:

| Icon | Rating |
|---|---|
| Green check | :ui[studied normally] |
| Yellow forward arrow | :ui[skimmed] |
| Grey dash | :ui[never opened] |

The bottom row under a theory column shows the :ui[Share of students who studied it normally].

## Status filter

In :ui[Scores + engagement] mode the filter panel gains a :ui[Group Radar status] list. It leaves only students with the selected status in the gradebook (the status covers the whole course). :ui[Any status] removes the filter.

## Cell panel

The hint ":ui[Click a cell to see why.]" means that clicking a task cell opens a panel with an explanation. The panel shows:

1. **Score, :ui[Attempts] and :ui[Group avg]** – the group's average score on the task.
2. **Verdict** – one sentence on how the result and the theory relate (rules below).
3. **Violation**, if the cheating monitor has a verdict on the attempt.
4. **:ui[Theory in front of this task]** – each theory block with its rating and an :ui[Open] link to that block on the :ui[Course Radar] in the student's lens. Without theory it reads ":ui[This task has no theory right before it.]".
5. **Links**: :ui[Open the answer] – the answer in the grading center; :ui[Student card in group radar] – the student's card on the :ui[Group Radar].

### Verdict rules

Checked top to bottom; the first match applies. "Weak theory" means at least one theory block was never opened or was skimmed; the pass mark is 50.

| Situation | Verdict |
|---|---|
| No answer, weak theory | :ui[Not started yet - and the theory in front of it hasn't been studied either.] |
| No answer | :ui[Not started yet.] |
| Awaiting manual review | :ui[Waiting for a teacher's grade.] |
| Being checked | :ui[Being checked right now.] |
| Below the pass mark, weak theory | :ui[Most likely the topic wasn't learned: the theory in front of the task was skipped or skimmed.] |
| Below the pass mark, no theory before the task | :ui[Below the pass mark. There is no theory in front of this task to compare with.] |
| Below the pass mark, theory studied | :ui[The theory was studied, yet the task failed - the topic itself may be unclear; worth going through it together.] |
| Passed, weak theory | :ui[Passed even though the theory was skipped or skimmed - they may have known the topic already.] |
| Passed, theory studied | :ui[Passed, with the theory studied normally.] |

> [!NOTE]
> The verdict is inferred from block positions in the course and behaviour in the player. If the theory for a task is elsewhere in the course or was studied outside the platform, the verdict may be inaccurate.
