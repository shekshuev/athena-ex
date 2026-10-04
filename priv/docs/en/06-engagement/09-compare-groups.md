%{
  title: "Comparing groups",
  description: "How the groups taking one course differ."
}
---
## Purpose

The comparison screen answers the question "how do the groups (or teams) taking one course differ, and where to look first". It compares up to five groups on eight indicators and by course section.

## How to open

On any engagement screen of the course (:ui[Group Radar] or :ui[Course Radar]), click :ui[Compare Cohorts] to the right of the tabs.

The screen requires the `engagement.read` permission. For a competition course, teams are compared instead of groups.

## Screen elements

### Choosing groups and the period

Under the heading are all groups enrolled in the course that the user can access. Clicking a group adds it to or removes it from the comparison. At most five groups can be selected at once; on first opening, the first five are selected.

On the right is the period selector: :ui[Last 7 days] (default), :ui[Last 30 days], :ui[Whole course]. The selected groups and period are kept in the page address.

### At a glance

The :ui[At a glance] block holds up to six statements worth reading first, in this order:

1. **Clearly worse indicators.** For each group and indicator where the deviation from the course average reaches level two (see below) in the unfavourable direction: "*group*: *indicator* – *value* against *average* on average".
2. **Topics hard for everyone** (only with more than one group selected). A section is listed if it has at least 3 graded answers, the average score across all groups is below 60, and no group reaches an average of 60 in it.
3. **Lagging in a section.** A group has completed a section 25 or more percentage points less than the selected groups on average.

If none of this applies, it reads ":ui[No group stands out - they are within a few points of each other.]".

### Indicator table

The table's columns are the selected groups (with their number of students) and the :ui[Course average] column. Rows are grouped by meaning. Each indicator has a "?" icon with a tooltip.

| Group | Indicator | Formula | Period | Better if |
|---|---|---|---|---|
| :ui[Progress] | :ui[Course completed] | Average across students of the share of course blocks completed | Whole course | higher |
| :ui[Progress] | :ui[Not engaging in this period] | Share of students with the :ui[Not engaging] status | Period | lower |
| :ui[Results] | :ui[Average score] | Average best score over every graded task submitted | Whole course | higher |
| :ui[Results] | :ui[Passed on the first attempt] | Share of submitted tasks where the pass mark (50) was reached on the first attempt | Whole course | higher |
| :ui[How they learn] | :ui[Rush through the material] | Share of students for whom rushing is a consistent pattern (the :ui[Skimming] condition) | Period | lower |
| :ui[How they learn] | :ui[Get stuck] | Share of students for whom difficulties are a consistent pattern (the :ui[Struggling] condition) | Period | lower |
| :ui[Integrity] | :ui[Exam violations] | Share of students with at least one :ui[Integrity] signal | Period | lower |
| :ui[Integrity] | :ui[Attempts flagged by the cheating monitor] | Share of attempts (the best attempt of each task) the cheating monitor rated high risk, or the teacher confirmed as a violation | Whole course | lower |

:ui[Rush through the material] and :ui[Get stuck] count a student regardless of their final status: a student with :ui[Integrity risk] and consistent rushing counts in both indicators.

### Course average

The :ui[Course average] column is not an average of the groups' values but the value computed over the **union** of the selected groups: the numerators and denominators of all groups are added up. So a large group weighs more than a small one, as it should when counting by student.

### Deviations

Each group value is compared with the average, and the cell is coloured:

| Level | Difference from the average | Appearance |
|---|---|---|
| 0 | under 10 points (for :ui[Average score] – under 8) | no highlight |
| 1 | from 10 points (for :ui[Average score] – from 8) | one arrow; green background if better, yellow if worse |
| 2 | from 20 points (for :ui[Average score] – from 15) | two arrows; green background if better, red if worse |

The arrow shows whether the value is above or below the average; "better" or "worse" follows the "Better if" column.

### Drilling down to the group radar

Every cell of the table links to that group's :ui[Group Radar] with the same period and a status filter matching the indicator:

| Indicator | Filter on the :ui[Group Radar] |
|---|---|
| :ui[Course completed] | :ui[Falling behind] |
| :ui[Not engaging in this period] | :ui[Not engaging] |
| :ui[Average score], :ui[Passed on the first attempt] | :ui[Not mastering the material] |
| :ui[Rush through the material] | :ui[Skimming] |
| :ui[Get stuck] | :ui[Struggling] |
| :ui[Exam violations], :ui[Attempts flagged by the cheating monitor] | :ui[Integrity risk] |

### Topics × groups

The :ui[Topics × groups] matrix shows the course's sections (rows) for each selected group (columns). A switch above the matrix selects the figure:

- :ui[Average score] – average best score on the section's graded tasks, whole course;
- :ui[Completed] – share of the section's blocks completed by the group's students ("student × block" pairs), whole course.

Cell colour:

| Value | Colour |
|---|---|
| under 50 | red |
| 50–69 | yellow |
| 70–84 | light green |
| 85 and above | green |
| no data | "–" |

## How to read it

- Read :ui[At a glance] first: significant differences are already picked out there.
- Cells without highlighting need no attention: the difference from other groups is below the threshold.
- A matrix row that is red for every group points to the section's material, not to the groups; open that section on the :ui[Course Radar].
- Check a difference in one indicator of one group by following the cell to the :ui[Group Radar]: it shows how many students, and which, stand behind it.
