%{
  title: "Roles and permissions",
  description: "How permissions decide which areas and actions a user can access."
}
---
## How access works

Access in the system is decided not by a user's position but by a set of permissions. The arrangement has three levels:

1. A **permission** – leave to perform one action on one kind of record, for example `courses.read`.
2. A **role** – a named set of permissions, composed by the administrator.
3. An **account** – holds exactly one role.

The question "what can this user do" therefore always comes down to the list of permissions in their role. The system has no predefined roles: names such as "teacher" or "student" belong not to the system but to a role that the administrator of a given installation created.

## How a permission is written

A permission is written as `area.action`.

| Action | What it allows |
|---|---|
| `create` | Creating new records |
| `read` | Viewing records and the corresponding areas |
| `update` | Changing existing records |
| `delete` | Deleting records |

Not every area defines all four actions. Marking, for instance, has only `grading.read` and `grading.update`, settings have `settings.read` and `settings.update`, and the `docs.read` permission stands on its own.

## Permission areas

| Area | What it covers |
|---|---|
| `users`, `roles` | Accounts and roles |
| `courses`, `competitions` | Courses and competitions |
| `library`, `characters` | The block library and dialogue characters |
| `surveys` | Surveys |
| `cohorts`, `teams` | Groups and teams |
| `instructors` | The list of instructors |
| `grading` | Marking and the gradebook |
| `engagement` | The engagement module |
| `gamification` | Badges, sprints and other achievements |
| `files` | Files and storage quotas |
| `announcements` | Announcements |
| `settings` | System settings |
| `docs` | This documentation |

Two permissions stand apart, belonging to no area: `system.cache` allows the cache to be cleared, and `admin` grants full access.

## The `admin` permission

The `admin` permission is an exception to the general arrangement: a role that holds it gains access to everything, whatever else is ticked. In the list of roles such a role is marked :ui[Super Admin] rather than by a count of permissions. It is best granted to as few roles as possible, since it also bypasses the "own records only" restriction described below.

## Policies: the "own records only" restriction

Permissions answer the question "which action is allowed", while policies answer "on whose records". A policy is set for an individual permission within a role.

One policy is available – own records only. It confines the permission to records the user owns. The `courses.update` permission without a policy allows any course to be changed; with the policy, only the courses that user created.

The policy applies to lists as well: the user is not refused when trying to open someone else's record, they simply do not see it listed. This matters when looking into a report: "the course is not in the list" and "the course is not accessible" look the same to a user but mean different things.

## How permissions show in the interface

The sidebar is built from permissions, and on two levels:

- an **item** is shown if the corresponding read permission is held;
- a **whole group** (:ui[Studio], :ui[Teaching], :ui[Admin]) is hidden if no permission for any of its items is held.

Hence a rule for looking into reports: if a user does not see an area, check the permissions of their role first and only then look for a fault. Inside the areas the same holds for individual buttons: a create button, for instance, is not displayed without the `create` permission.

## Managing roles

Roles live in :ui[Admin] › :ui[Roles]; the area requires the `roles.read` permission.

The table of roles holds the name, the access level (:ui[Super Admin], or the number of ticked permissions) and the date of creation. The :ui[Create Role] button opens the creation form, and the pencil icon the edit form.

The form asks for :ui[Role Name], and permissions are ticked in the :ui[Permissions & Policies] block. Permissions are grouped by area, and each ticked permission may additionally be given a policy. The form is stored with :ui[Save].

### Deleting a role

A role assigned to at least one account cannot be deleted: the system refuses and reports that the role is assigned to users. To delete such a role, first move those accounts to another role in :ui[Admin] › :ui[Users].

### Changing a role

A change to the set of permissions takes effect at once, including for those already working in the system: menu items and buttons appear or disappear on the next move, without signing in again.

## Related pages

| Task | Page |
|---|---|
| Create an account and assign it a role | [Users](/docs/administration/users) |
| Roles and policies in detail | [Roles and permissions](/docs/administration/roles-permissions) |
| Permissions belonging to engagement | [Engagement: overview](/docs/engagement/overview) |
| Access to one course within a group | [Course access](/docs/groups/access) |
