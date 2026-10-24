%{
  title: "Sign-in, password and profile",
  description: "Signing in, changing the password and setting up your own profile."
}
---
## Signing in

Accounts are created by the administrator; there is no self-registration. The login and the initial password are issued by the administrator (see [Users](/docs/administration/users)).

The sign-in page has two fields:

1. :ui[Login] – the login that was issued.
2. :ui[Password] – the password.

Clicking :ui[Log in] opens the :ui[Dashboard]. If the pair does not match, the message :ui[Invalid login or password] appears; it is the same for a wrong password and for a login that does not exist, so it cannot be used to tell whether an account exists.

### Temporary lock

After three consecutive failed attempts the account is locked for **30 minutes**. During that time signing in fails even with the correct password. The lock is lifted automatically when the period expires; the failed-attempt counter resets on the first successful sign-in. An administrator can release the account earlier by changing its status.

### Mandatory password change

A new account is marked as requiring a password change by default, so on the first sign-in the :ui[Security Update Required] screen opens instead of the requested page. Until a new password is set, the other areas are unavailable. An administrator can set the requirement later as well, for instance after issuing a temporary password.

The screen asks for :ui[New Password] and :ui[Confirm New Password], followed by :ui[Save and continue]. The two fields must match, and the password itself must satisfy the requirements that hold throughout the system:

- at least eight characters;
- at least one uppercase and one lowercase letter;
- at least one digit;
- at least one special character.

## Your own profile

The profile opens by clicking the user name at the bottom of the sidebar. The page is called :ui[My Account] and has two tabs:

| Tab | Contents |
|---|---|
| :ui[Profile] | Personal details, profile picture, password change |
| :ui[Achievements] | Level, badges and the weekly league (see [Achievements](/docs/achievements/xp-levels)) |

### Personal details

The :ui[Personal Information] block holds the :ui[First Name], :ui[Last Name] and :ui[Patronymic] fields. The last and first names are required: they form the name the system shows to other users – in the gradebook, in group lists and in messages. Until the profile is filled in, the login is displayed instead of a name. Changes are stored with :ui[Save changes].

### Profile picture

The :ui[Avatar] block allows an image to be uploaded. The order is: :ui[Choose image], pick a file, then :ui[Save avatar]. JPG, PNG, GIF and WebP files of up to 5 MB are accepted. With no image uploaded, the system shows a circle with the first two characters of the login.

### Changing the password

The :ui[Password] block requires three fields: :ui[Current Password], :ui[New Password] and :ui[Confirm New Password]. The change is confirmed with :ui[Update password]. The current password is asked for so that a page left unattended cannot be used by a stranger to change it. If the current password is wrong, the password is not changed and the field is marked with an error.

The new password is checked by the same rules as a mandatory change: at least eight characters, an uppercase and a lowercase letter, a digit and a special character.

### Taking part in the weekly league

The :ui[Show me to others in the league] switch decides whether other members of the league see this user's row. With the switch off, one's own result is still counted and visible to oneself, but is not shown in the shared table. See [Leagues](/docs/achievements/leagues) for more.

## Instructor details

If the account is on the list of instructors (see [Instructors](/docs/groups/instructors)), the :ui[Profile] tab gains an extra :ui[Instructor] block with the :ui[Post] and :ui[Biography] fields. These details are filled in not by the user but in :ui[Teaching] › :ui[Instructors]; in the profile they are read-only and visible to anyone who opens that user's page.

## Signing out

The :ui[Log out] item sits at the very bottom of the sidebar. It ends the session; continuing work requires signing in again.
