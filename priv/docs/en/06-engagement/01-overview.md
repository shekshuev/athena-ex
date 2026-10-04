%{
  title: "Overview",
  description: "What the module is for, its screens and the required permissions."
}
---
## Purpose

The engagement module records **how** students go through a course, not only **what result** they get. From actions in the course player and during assessments it builds per-block measurements and answers three questions for the teacher:

1. **Who** in the group needs attention, and why – the :ui[Group Radar] screen.
2. **Where** in the course the group has difficulties – the :ui[Course Radar] screen.
3. **How** the groups taking the same course differ – the :ui[Compare Cohorts] screen.

In addition, the gradebook in :ui[Scores + engagement] mode shows, next to a task's score, how the student went through the theory before it.

The module does not grade anyone and takes no automatic action against a student. Its only direct effect on students is short nudges in the player, which are off by default (see [Settings and nudges](/docs/engagement/settings-nudges)).

## How to open

Every engagement screen is opened from a group's or team's page:

1. :ui[Teaching] › :ui[Cohorts] (for teams – :ui[Teaching] › :ui[Teams]).
2. Open the group.
3. In the :ui[Assigned Courses] table, click :ui[Engagement] in the course's row.

This opens the :ui[Course Radar] of that course for the selected group. At the top of the screen there is a three-tab switch shared by all of the course's analytics screens:

| Tab | What it shows | Required permission |
|---|---|---|
| :ui[Group Radar] | Each student's status and its reasons | `engagement.read` |
| :ui[Course Radar] | Course map with problem spots, block detail, activity charts | `engagement.read` |
| :ui[Gradebook] | The gradebook, including :ui[Scores + engagement] mode | `grading.read` (the engagement mode also needs `engagement.read`) |

Next to the tabs, the :ui[Compare Cohorts] button opens a comparison of every group (or team) enrolled in the course.

The :ui[Assigned Courses] table also has a :ui[Gradebook] button that opens the gradebook directly.

## Permissions

| Permission | What it grants |
|---|---|
| `engagement.read` | The :ui[Engagement] button, the :ui[Group Radar], :ui[Course Radar] and :ui[Compare Cohorts] screens, the :ui[Scores + engagement] gradebook mode |
| `engagement.update` | The :ui[Engagement Tracking] panel in the course builder's inspector (expected time, fast-completion threshold, allowing nudges) |
| `grading.read` | The gradebook, opening students' answers, the :ui[Scores in gradebook] link in the student card |

Permissions are assigned to roles in :ui[Admin] › :ui[Roles]. An administrator has access to everything without separate permissions.

## Contents of this section

| Page | Contents |
|---|---|
| [Data collection](/docs/engagement/data-collection) | Which actions are recorded and with which limitations |
| [Settings and nudges](/docs/engagement/settings-nudges) | Expected block time, nudges to students |
| [Metrics reference](/docs/engagement/metrics) | Definition and formula of every block metric |
| [Signals reference](/docs/engagement/signals) | When each signal fires |
| [Group radar](/docs/engagement/group-radar) | Student statuses, rules, the student card |
| [Course radar](/docs/engagement/course-radar) | Course map, block detail, the :ui[Activity] tab |
| [Gradebook: scores and engagement](/docs/engagement/gradebook-layer) | Markers, theory columns, the cell panel |
| [Comparing groups](/docs/engagement/compare-groups) | Indicators, deviations, the :ui[Topics × groups] matrix |
| [Data processing](/docs/engagement/data-processing) | Periods, pre-aggregation, delays |
| [Thresholds reference](/docs/engagement/thresholds) | Every configurable threshold |
| [Interpretation and limitations](/docs/engagement/interpretation) | How to read the numbers, common questions |

Signs of dishonest behaviour during an assessment are described in detail in [Academic integrity](/docs/grading/academic-integrity).
