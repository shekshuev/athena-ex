%{
  title: "Data processing",
  description: "Periods, pre-aggregation, refresh and delays."
}
---
## Data path

Data goes through four steps:

1. **Collection.** The student's browser sends events in batches every 10 seconds (see [Data collection](/docs/engagement/data-collection)). The server stores them as they are.
2. **Pre-aggregation.** A background job folds new events into daily totals every 5 minutes: one record per "group × student × block × day".
3. **Screen computation.** When a screen opens, past days of the period are read from the daily totals and today from the raw events. Both parts are added up and go through the same formulas.
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

If totals have not been built yet, or the job is more than 15 minutes behind, the screens temporarily compute everything from raw events. The result is the same, but slower.

## Delays

| What changed | When it shows on screen |
|---|---|
| A new action by a student | 10–20 seconds after the action (batch sending) plus up to 60 seconds of cache |
| Metrics of an open block detail | Update by themselves as events arrive, at most once every 2 seconds |
| :ui[Group Radar], course map, group comparison | When the screen is opened or the period changed, not before the 60-second cache expires |
| A new grade from a teacher | On the next screen computation |

The :ui[Group Radar] and the course map do not refresh by themselves while open: they are a snapshot at the time of computation. To see fresh data, reload the page or change the period.

## Limitations of daily buckets

Within-session measurements (visit time, reading depth, video skipping, time to first action, returns) are taken within one calendar day. A session running past midnight counts as two. This is the only approximation daily aggregation introduces.
