%{
  title: "Interpretation and limitations",
  description: "How to read the numbers, what the system cannot see, and common questions."
}
---
## General principles

1. **A status is a reason to look closer, not a grade.** The module points out behaviour that is statistically associated with learning difficulties, but it does not establish the cause.
2. **Comparison with the group, not with an ideal.** Most rules compare a student with their group on the same block. "Too fast" means "much faster than usual in this group", not "faster than the author intended".
3. **A pattern, not an episode.** The :ui[Skimming] and :ui[Struggling] statuses require repeated behaviour on a noticeable share of blocks. Individual signals are visible in the card but do not change the status.
4. **A task's problem differs from a student's problem.** If most of the group fails a task, a low score on it is not a student signal, and the block appears on the course map as a problem spot.
5. **Small samples do not define the norm.** Group comparison needs data from at least 5 students, course map problem spots need 3.

## What the system cannot see

- **Study outside the platform**: a textbook, a lecture, notes, help from a classmate. A student who learned the topic from a textbook will look as if they skipped the theory.
- **Reasons for absence**: illness, exams in another subject and loss of interest look the same.
- **A second device** and screenshots taken by the operating system (except the PrintScreen key on Windows).
- **Attention**: an open page with no activity counts as time on the block for up to 2 minutes.
- **Long text**: reading of a block taller than the browser window is understated (see [Data collection](/docs/engagement/data-collection#how-reading-of-text-is-measured)).

## Recommended routine

1. **Once a week**, open the :ui[Group Radar] with :ui[Last 7 days]. Start with the :ui[Not engaging] and :ui[Integrity risk] tiles.
2. For each flagged student, open the card and read :ui[What counted]: a status is always explained by specific signals.
3. If many students share similar signals, go to the :ui[Course Radar]: the cause is probably the material, which shows up in :ui[Problem spots in the course].
4. After talking to a student or changing the material, compare :ui[Last 7 days] with previous weeks: the status reflects current behaviour and changes when behaviour changes.

## Common questions

### Why does the whole group need attention?

If almost no student is :ui[On track], check:

- **Whether there is a common signal.** If most students have the same chip (say, :ui[Low score] on the same task), open that task on the course map. A task the group as a whole passed but some students failed gives individual signals; a task almost everybody failed gives no low-score signals to students.
- **Whether there are long text blocks.** :ui[Doesn't read to the end] systematically fires on texts taller than the browser window. It does not change the status by itself, but can add up to a :ui[Skimming] pattern.
- **Whether the group is too small.** With fewer than 5 students there is no group comparison, and only fixed thresholds apply, which may not suit the course material.
- **Whether the expected time is realistic.** If a block's expected time is far too high, many students will get :ui[Too fast]. Remove the expected time so that the group's median is used instead.

### Why does the status on the group radar differ from the gradebook filter?

The gradebook in :ui[Scores + engagement] mode always computes the status over the whole course, while the :ui[Group Radar] uses the selected period (7 days by default). With :ui[Whole course] the statuses match.

### Why is a student who did nothing "On track"?

The :ui[No activity] signal fires only if someone in the group was active during the period. If nobody was, nobody gets :ui[Not engaging]. Also check the period: with :ui[Whole course] the entire history counts.

### Why has the status not changed after I talked to the student?

A status for :ui[Last 30 days] or :ui[Whole course] includes past behaviour. Look at :ui[Last 7 days]: a week after behaviour changes, old signals leave the period. Screens also update with a delay of up to a few minutes (see [Data processing](/docs/engagement/data-processing)).

### Why is a problem spot on the map not visible in a student's lens?

Problems on the course map in the :ui[Whole cohort] lens describe the group (for example, "fewer than 60% passed"). A student's lens shows only that student's own signals on the block.

### Does "Integrity risk" mean the student cheated?

No. The status means at least one sign was recorded during an assessment: a copy attempt, a screenshot, a second tab, frequent leaving of the page or a pasted answer. The decision is made by the teacher after reviewing the attempt in the cheating monitor (see [Academic integrity](/docs/grading/academic-integrity)). A teacher's :ui[Reviewed - no violation] removes the gradebook marker but not the signal on the group radar: the radar shows recorded behaviour.

### Can thresholds be changed?

Thresholds are set in the application configuration and apply to every course (see [Thresholds reference](/docs/engagement/thresholds)). Per section and block, the expected time and allowing nudges can be set.

### Does a student see their status?

No. The engagement screens are only available to users with the `engagement.read` permission. A student only sees nudges in the player, if they are enabled.
