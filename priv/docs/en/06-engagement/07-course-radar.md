%{
  title: "Course radar",
  description: "Where in the course the difficulties are: course map, block detail and activity."
}
---
## Purpose

The :ui[Course Radar] answers the question "where in the course does the group (or one student) have difficulties". The screen has three parts:

- the **course map** – every block of the course with the group's figures and problem spots marked (the :ui[Map] tab, opened by default);
- the **block detail** – one block's metrics, weekly trend and time distribution;
- the **:ui[Activity] tab** – charts on when and how much the group studies.

## How to open

1. :ui[Teaching] › :ui[Cohorts] › the group.
2. In the :ui[Assigned Courses] table, click :ui[Engagement] in the course's row.

The :ui[Course Radar] opens immediately. From other screens, use the :ui[Course Radar] tab at the top.

## Screen elements

### Course tree

On the left is the tree of the course's sections. :ui[Whole course] shows the whole map; selecting a section narrows the map to that section. Above the tree are a link back to the group and the names of the course and group.

### The "Looking at" lens

The :ui[Looking at] drop-down to the right of the heading sets whose figures are shown:

- :ui[Whole cohort] – the whole group (default);
- a student's name – that student's figures on every block next to the group's.

The lens applies to both the map and the block detail.

### Period

Next to the lens is the period selector: :ui[Last 7 days] (default), :ui[Last 30 days], :ui[Whole course]. The period affects behaviour (who opened a block, how long they spent, signals that fired). Block completion and scores always cover the whole course. The period selector is not shown in block detail.

## Course map

### Problem spots

At the top of the map is the :ui[Problem spots in the course] list (in a student's lens – "Where … has trouble"). It holds up to five of the most problematic blocks of the visible part of the course, ordered:

1. high-severity blocks first;
2. then by the number of problems on the block, descending;
3. then in course order.

Each entry shows a number, the block name and a short description of the problems. Clicking it opens the block detail.

### Block rows

Below, the map shows the course's sections in order, indented by nesting level. A section header shows the number of blocks and the number of problem spots. Each block is a row:

- a **coloured stripe on the left**: red – high severity, yellow – medium, none – no problems;
- the **block type icon and name**;
- **problem chips** (for the group) or **signal chips** (for a student);
- **figures on the right**.

Figures for the group:

| Figure | Meaning |
|---|---|
| *opened*/*total* and *completed* | How many students opened the block during the period, out of how many in the group, and how many completed it (whole course) |
| Time | :ui[Average time on the block] during the period |
| Score · share | Average best score and share who passed (score of at least 50); red if fewer than 60% passed |

Figures for a student:

| Figure | Meaning |
|---|---|
| Time | The student's average time / the group's median |
| Score | The student's best score, number of attempts ("×N"); ":ui[review]" if the answer awaits review |
| :ui[not opened] | The student did not open the block during the period |

The :ui[Only problem spots] switch leaves only blocks with problems on the map. Sections with nothing left are hidden.

Clicking a row opens the block detail.

### Problem spot rules (group)

A group-level problem is raised only when **at least 3 students** stand behind the figure (opened the block or were graded on it), so two people never make a block "problematic".

| Problem | Chip | Condition | Critical |
|---|---|---|---|
| Low scores | :ui[Low scores] | ≥ 3 students graded, and fewer than 60% of them reached the pass mark (50) | If fewer than 40% did |
| Many attempts | :ui[Many attempts] | ≥ 3 students have attempts, and they average at least 2.5 | No |
| Rushed through | :ui[Rushed through] | ≥ 3 students opened it, and at least 40% of them have at least one :ui[Rushing] signal on the block | No |
| Students get stuck | :ui[Students get stuck] | ≥ 3 students opened it, and at least 40% of them have at least one :ui[Difficulties] signal on the block | No |
| Students come back | :ui[Students come back] | :ui[Share who came back] > 0.4 | No |
| Answers keep changing | :ui[Answers keep changing] | :ui[Share who changed answers] > 0.4 | No |

**Block severity** is high if at least one problem is critical, and medium if there are problems but none is critical.

### Rules in a student's lens

In a student's lens a block shows that student's signals:

- every behaviour signal on the block (categories :ui[Rushing], :ui[Difficulties], :ui[Integrity], see [Signals reference](/docs/engagement/signals));
- :ui[Low score] – best score below 50 (unlike the group radar, without the group-median condition);
- :ui[Many attempts] – at least 3 attempts and at least twice the group's average number of attempts on the block.

Severity is high if the signals include an :ui[Integrity] signal or :ui[Low score], and medium otherwise.

## Block detail

Opened by clicking a block row or an entry of the problem spots list. At the top are the :ui[Back to course map] button and, for graded blocks, :ui[View Submissions] – the answers to this block in the grading center, filtered to the group (requires the `grading.read` permission).

Block detail always covers **the whole history of the course** for this group, regardless of the selected period.

| Element | Contents |
|---|---|
| Metric grid | Every metric of the block for the group or for the student in the lens. Definitions in the [Metrics reference](/docs/engagement/metrics) |
| :ui[Weekly trend] | A table by week (weeks start on Monday). The drop-down selects the figure: :ui[Avg dwell (s)], :ui[Sample size] (number of visits), :ui[Nudges shown] |
| :ui[Dwell distribution] | A histogram of the group's visit times on the block. The bottom 10% is highlighted in red: below this line a fast-completion nudge is shown when nudges are enabled |

While block detail is open, metrics update as new events arrive (at most once every 2 seconds).

## The Activity tab

The :ui[Activity] tab is next to :ui[Map] above the map. Its charts load the first time the tab is opened and follow the selected period.

| Chart | What it shows | How it is computed |
|---|---|---|
| :ui[Activity heatmap] | When the group studies | A "day of week × hour" grid (application time zone); the value is the number of events of any kind |
| :ui[Course funnel] | How far the group gets through the sections | For each section: how many students opened at least one block; how many of them interacted with blocks (block leaving the screen, paste, video play, attachment open, image zoom); how many of those who opened it completed every block of the section (whole course) |
| :ui[Nudge correction rate] | Whether nudges help | For each nudge reason: the share of nudges after which the same signal never fired again for the same student on any course block where it can fire at all |
| :ui[Active students] | How many students study | For each day with activity – the number of students with at least one event. Days without activity are not shown |

> [!NOTE]
> :ui[Nudge correction rate] only shows data if nudges are enabled for the group (see [Settings and nudges](/docs/engagement/settings-nudges)).

## Typical workflow

1. Open the :ui[Course Radar] with the :ui[Last 30 days] period and turn on :ui[Only problem spots].
2. Start with the :ui[Problem spots in the course] list: red entries are blocks where fewer than 40% of those graded reached the pass mark.
3. Open the block. If :ui[Low scores] comes with :ui[Rushed through] on the theory before it, the likely cause is superficial study of the theory. If the theory was studied normally, the task itself or the explanation of the topic is worth revisiting.
4. To see who is affected, switch :ui[Looking at] to a specific student or go to the :ui[Group Radar].
