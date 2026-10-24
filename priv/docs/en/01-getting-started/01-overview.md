%{
  title: "Athena overview",
  description: "What the system is for, its main parts and user roles."
}
---
## Purpose

Athena is a learning management system that keeps course material, assessment and analytics in one place. It serves two sides of the teaching process:

1. A **student** takes a course in the player: reads the theory, solves tasks, sits assessments and sees their own result.
2. A **teacher** builds the course, assigns it to a group or a team, marks the answers and watches how the group progresses.

What sets the system apart from a plain repository of materials is that it records not only the **result** of a student's work but also its **course**: time spent on a block, repeated attempts, the order of moves. These data form a separate engagement module (see the [Engagement](/docs/engagement/overview) section).

## Main parts

The system's areas are collected in the sidebar in four groups. A menu item is visible only to those who hold the matching permission (see [Roles and permissions](/docs/getting-started/roles)).

| Group | Purpose | Main items |
|---|---|---|
| :ui[Learn] | Everything to do with the user's own learning | :ui[My Learning], :ui[Schedule], :ui[My Files], :ui[Announcements], :ui[Messenger], :ui[Documentation] |
| :ui[Studio] | Authoring of learning content | :ui[Course Manager], :ui[Competitions], :ui[Library], :ui[Surveys], :ui[Characters] |
| :ui[Teaching] | Work with groups and marking | :ui[Assignments], :ui[Cohorts], :ui[Teams], :ui[Instructors], :ui[Sprints] |
| :ui[Admin] | System administration | :ui[Users], :ui[Roles], :ui[Files], :ui[Announcements], :ui[System Settings], :ui[Badges] |

Above the groups, as an item of its own, sits :ui[Dashboard] – the summary that work starts from: upcoming deadlines, recent announcements and one's own progress.

## Learning units

The system rests on four concepts that are worth telling apart from the outset.

| Concept | What it is | Where it is created |
|---|---|---|
| Course | A sequence of sections and blocks: theory, tasks, assessments | :ui[Studio] › :ui[Course Manager] |
| Competition | A course of a special type, meant for team participation and having a leaderboard | :ui[Studio] › :ui[Competitions] |
| Group | A standing set of students that courses are assigned to | :ui[Teaching] › :ui[Cohorts] |
| Team | A set of participants that competitions are assigned to | :ui[Teaching] › :ui[Teams] |

A course on its own is not available to students. It becomes available once it has been assigned to a group; from that moment the group and the course are tied by an enrolment record (see [Members and courses](/docs/groups/members-courses)).

## User roles

The system has no predefined set of roles. A role is a named set of permissions that the administrator composes, so the exact role names in a given installation are decided by its administrator. A typical division looks like this:

- **student** – permission to read the courses assigned to their group, and their own results;
- **teacher** – in addition, permissions to author courses, mark work and view the analytics of their groups;
- **administrator** – the `admin` permission, which grants full access.

Composing roles, and restricting a permission to one's own records, are covered in detail in [Roles and permissions](/docs/getting-started/roles).

## Where to start

| Task | Page |
|---|---|
| Sign in and set up a profile | [Sign-in, password and profile](/docs/getting-started/sign-in) |
| Find your way around the menu, language and appearance | [Interface](/docs/getting-started/interface) |
| Understand what decides access | [Roles and permissions](/docs/getting-started/roles) |
| Take a first course | [Learning](/docs/learning/dashboard) |
| Build a first course | [Course authoring](/docs/authoring/course-manager) |
