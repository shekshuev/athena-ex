%{
  title: "Interface",
  description: "The main menu, interface language, light and dark theme, time zone."
}
---
## Layout of the page

The working space is divided in two: a permanent sidebar on the left and the content area on the right. The content scrolls independently of the menu, so moving between areas does not lose the menu's position.

On a narrow screen the sidebar is tucked away and is called up by a button at the top of the page; clicking the dimmed area closes it again. On a wide screen the menu can be collapsed to a strip of icons alone – the item names are hidden, while the order of the areas is kept.

## The sidebar

Menu items are collected into the :ui[Learn], :ui[Studio], :ui[Teaching] and :ui[Admin] groups, with :ui[Dashboard] above them. What the menu contains depends on permissions: a whole group is not shown if the user holds no permission for any of its items. Two users of the same installation therefore see menus of different size, and a missing item means a missing permission, not a missing area (see [Roles and permissions](/docs/getting-started/roles)).

At the bottom of the menu sit the controls that do not belong to the teaching process:

| Control | Purpose |
|---|---|
| Language switch | Shows the current language (`RU` or `EN`) and switches to the other |
| Appearance switch | Light and dark theme |
| User name | Opens one's own profile |
| :ui[Log out] | Ends the session |

## Interface language

Russian and English are supported. The switch at the bottom of the menu is labelled with the current language: `EN` means the interface is in English at the moment, and clicking it switches to Russian.

The choice of language is kept for the working session and applies to the whole interface, this documentation included: it is written in both languages, and switching opens the same page in the other one. Course content is not translated – it is shown in the language its author wrote it in.

## Light and dark theme

The switch with the sun and moon icons changes the appearance. The choice is stored in the browser, so it applies only on the device where it was made, and it survives between sessions. Until a choice is made, the system follows the appearance setting of the operating system.

The theme affects course content too: syntax highlighting and elements carrying status colours are chosen to work in both appearances.

## Time zone

There is no separate time-zone setting. The browser reports its zone to the system when a page is opened, and every date and time is shown in it: deadlines, times of answers, last-seen marks. A student and a teacher in different zones therefore see the same deadline, each in their own local time.

All timestamps are stored on a single scale, so changing zone or moving does not shift events that are already recorded. If the browser has not reported a zone, the zone configured by the installation's administrator applies.

## Screen size limits

Most areas are adapted to a narrow screen. The exception is the course builder: it requires a desktop or tablet screen and, on a narrow one, shows a notice that the screen is too small instead of the editor. The reason is that the builder shows the course structure, the block's working area and the property inspector at the same time.

## Documentation

This documentation is opened by the :ui[Documentation] item in the :ui[Learn] group and is available to those holding the `docs.read` permission. It holds nothing about any particular course – only a description of the system itself.
