%{
  title: "Data processing",
  description: "Periods, pre-aggregation, refresh, delays and data retention."
}
---
## Data path

Data goes through four steps:

1. **Collection.** The student's browser sends events in batches every 10 seconds (see [Data collection](/docs/engagement/data-collection)). The server stores them as they are.
2. **Pre-aggregation.** A background job folds new events into daily totals every 5 minutes: one record per "group × student × block × day".
3. **Screen computation.** Course-wide screens (:ui[Group Radar], course map, group comparison, gradebook) read the whole period, today included, from the daily totals. Only the block detail on the :ui[Course Radar] adds today's raw events to the totals of past days, so that it stays live while students work. All of them go through the same formulas.
4. **Cache.** The result is kept for 60 seconds. Reopening or switching tabs within that time does not recompute it.

## Periods

The period "last N days" is today and the N − 1 previous full days in the application time zone. It starts at midnight of its first day. The :ui[Whole course] period has no time limit.

The period applies to behaviour (events) and to tasks submitted within it. The following do not depend on the period and always cover the whole course:

- course progress and block completion;
- scores on the course map, in the gradebook and in the :ui[Avg score] column of the :ui[Group Radar];
- :ui[Average score], :ui[Passed on the first attempt] and :ui[Attempts flagged by the cheating monitor] in the group comparison;
- the rating of theory before a task;
- block detail on the :ui[Course Radar];
- the whole :ui[Scores + engagement] gradebook mode.

## Pre-aggregation

Daily totals make the screens of a large course (hundreds of blocks, dozens of students, months of study) open quickly: already summed totals are read instead of millions of events.

Details:

- the job recomputes affected days **entirely** from raw events instead of adding to old totals. Late events (for example, a browser that was offline sends yesterday's events today) are therefore still counted correctly;
- the whole course section is recomputed, not just the affected block, because returns to blocks are determined within a section;
- events without a group are not aggregated.

Until the totals have been built for the first time, the screens compute everything from raw events. The result is the same, but slower. Once built, the totals are always used, even when the job is behind: the screens then show slightly older numbers instead of slowing down.

## Delays

| What changed | When it shows on screen |
|---|---|
| A new action by a student | On the block detail: 10–20 seconds after the action (batch sending). On course-wide screens: after the next pre-aggregation run (up to 5 minutes) plus up to 60 seconds of cache |
| Metrics of an open block detail | Update by themselves as events arrive, at most once every 10 seconds |
| :ui[Group Radar], course map, group comparison | When the screen is opened or the period changed, not before the 60-second cache expires |
| A new grade from a teacher | On the next screen computation |

The :ui[Group Radar] and the course map do not refresh by themselves while open: they are a snapshot at the time of computation. To see fresh data, reload the page or change the period.

## Limitations of daily buckets

Within-session measurements (visit time, reading depth, video skipping, time to first action, returns) are taken within one calendar day. A session running past midnight counts as two. This is the only approximation daily aggregation introduces.

## Storage and deletion

Raw events are kept indefinitely, stored month by month. The daily totals are kept indefinitely too.

An administrator can delete the raw events of one user (:ui[Delete activity data] in the user list) or of a whole group (the same button on the group page). The deletion:

- runs in the background, a few minutes after the request: it first waits until every event being deleted is included in the daily totals;
- keeps the daily totals, so every engagement screen shows the same numbers for past days as before;
- cannot be undone.

After the deletion:

- the proctoring timeline of that user's (or group's) past exams is empty;
- events recorded for them later on the same day as the request are not added to that day's totals; the following days are counted as usual.

