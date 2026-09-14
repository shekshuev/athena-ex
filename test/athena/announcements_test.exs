defmodule Athena.AnnouncementsTest do
  use Athena.DataCase, async: true

  alias Athena.Announcements
  alias Athena.Announcements.Announcement
  alias Athena.Learning.Cohorts
  import Athena.Factory

  setup do
    admin_role = insert(:role, permissions: ["admin"])
    admin = insert(:account, role: admin_role)

    instructor_role =
      insert(:role,
        permissions: [
          "announcements.create",
          "announcements.read",
          "announcements.update",
          "announcements.delete"
        ]
      )

    instructor_account = insert(:account, role: instructor_role)
    instructor_profile = insert(:instructor, owner_id: instructor_account.id)

    {:ok, my_cohort} =
      Cohorts.create_cohort(admin, %{
        "name" => "My Cohort",
        "instructor_ids" => [instructor_profile.id]
      })

    {:ok, other_cohort} = Cohorts.create_cohort(admin, %{"name" => "Other Cohort"})

    no_perms_role = insert(:role, permissions: [])
    no_perms_account = insert(:account, role: no_perms_role)

    %{
      admin: admin,
      instructor_account: instructor_account,
      my_cohort: my_cohort,
      other_cohort: other_cohort,
      no_perms_account: no_perms_account
    }
  end

  describe "create_announcement/2" do
    test "admin can create a global announcement", %{admin: admin} do
      assert {:ok, %Announcement{scope: :global}} =
               Announcements.create_announcement(admin, %{
                 "title" => "Global news",
                 "body" => "Hello everyone",
                 "scope" => "global"
               })
    end

    test "admin can create a cohort announcement for any cohort", %{
      admin: admin,
      other_cohort: other_cohort
    } do
      assert {:ok, %Announcement{scope: :cohort, cohort_id: cohort_id}} =
               Announcements.create_announcement(admin, %{
                 "title" => "Cohort news",
                 "body" => "Hello cohort",
                 "scope" => "cohort",
                 "cohort_id" => other_cohort.id
               })

      assert cohort_id == other_cohort.id
    end

    test "instructor can create an announcement for a cohort they instruct", %{
      instructor_account: instructor_account,
      my_cohort: my_cohort
    } do
      assert {:ok, %Announcement{}} =
               Announcements.create_announcement(instructor_account, %{
                 "title" => "My cohort news",
                 "body" => "Hello",
                 "scope" => "cohort",
                 "cohort_id" => my_cohort.id
               })
    end

    test "instructor cannot create an announcement for a cohort they don't instruct", %{
      instructor_account: instructor_account,
      other_cohort: other_cohort
    } do
      assert {:error, :forbidden} =
               Announcements.create_announcement(instructor_account, %{
                 "title" => "Not mine",
                 "body" => "Hello",
                 "scope" => "cohort",
                 "cohort_id" => other_cohort.id
               })
    end

    test "instructor cannot create a global announcement", %{
      instructor_account: instructor_account
    } do
      assert {:error, :forbidden} =
               Announcements.create_announcement(instructor_account, %{
                 "title" => "Global attempt",
                 "body" => "Hello",
                 "scope" => "global"
               })
    end

    test "account without announcements.create is rejected", %{
      no_perms_account: no_perms_account,
      my_cohort: my_cohort
    } do
      assert {:error, :forbidden} =
               Announcements.create_announcement(no_perms_account, %{
                 "title" => "Nope",
                 "body" => "Hello",
                 "scope" => "cohort",
                 "cohort_id" => my_cohort.id
               })
    end
  end

  describe "update_announcement/3" do
    test "instructor cannot re-scope their own cohort announcement to global", %{
      instructor_account: instructor_account,
      my_cohort: my_cohort
    } do
      {:ok, announcement} =
        Announcements.create_announcement(instructor_account, %{
          "title" => "Mine",
          "body" => "Hello",
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      assert {:error, :forbidden} =
               Announcements.update_announcement(instructor_account, announcement, %{
                 "scope" => "global"
               })
    end

    test "instructor cannot re-scope their own cohort announcement to a cohort they don't instruct",
         %{
           instructor_account: instructor_account,
           my_cohort: my_cohort,
           other_cohort: other_cohort
         } do
      {:ok, announcement} =
        Announcements.create_announcement(instructor_account, %{
          "title" => "Mine",
          "body" => "Hello",
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      assert {:error, :forbidden} =
               Announcements.update_announcement(instructor_account, announcement, %{
                 "cohort_id" => other_cohort.id
               })
    end

    test "instructor can edit title/body of their own cohort announcement", %{
      instructor_account: instructor_account,
      my_cohort: my_cohort
    } do
      {:ok, announcement} =
        Announcements.create_announcement(instructor_account, %{
          "title" => "Mine",
          "body" => "Hello",
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      assert {:ok, %Announcement{title: "Updated"}} =
               Announcements.update_announcement(instructor_account, announcement, %{
                 "title" => "Updated"
               })
    end
  end

  describe "delete_announcement/2" do
    test "instructor can delete their own cohort's announcement", %{
      instructor_account: instructor_account,
      my_cohort: my_cohort
    } do
      {:ok, announcement} =
        Announcements.create_announcement(instructor_account, %{
          "title" => "Mine",
          "body" => "Hello",
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      assert {:ok, _} = Announcements.delete_announcement(instructor_account, announcement)
    end

    test "instructor cannot delete another cohort's announcement", %{
      admin: admin,
      instructor_account: instructor_account,
      other_cohort: other_cohort
    } do
      {:ok, announcement} =
        Announcements.create_announcement(admin, %{
          "title" => "Not mine",
          "body" => "Hello",
          "scope" => "cohort",
          "cohort_id" => other_cohort.id
        })

      assert {:error, :forbidden} =
               Announcements.delete_announcement(instructor_account, announcement)
    end
  end

  describe "list_for_viewer/2" do
    test "student sees global announcements plus their own cohort's, not other cohorts'", %{
      admin: admin,
      my_cohort: my_cohort,
      other_cohort: other_cohort
    } do
      student = insert(:account)
      insert(:cohort_membership, account_id: student.id, cohort_id: my_cohort.id)

      {:ok, global} =
        Announcements.create_announcement(admin, %{
          "title" => "Global",
          "body" => "Hi",
          "scope" => "global"
        })

      {:ok, mine} =
        Announcements.create_announcement(admin, %{
          "title" => "Mine",
          "body" => "Hi",
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      {:ok, _other} =
        Announcements.create_announcement(admin, %{
          "title" => "Other",
          "body" => "Hi",
          "scope" => "cohort",
          "cohort_id" => other_cohort.id
        })

      {:ok, {announcements, meta}} = Announcements.list_for_viewer(student, %{})

      ids = Enum.map(announcements, & &1.id)
      assert meta.total_count == 2
      assert global.id in ids
      assert mine.id in ids
    end

    test "paginates via page_size", %{admin: admin} do
      for i <- 1..7 do
        Announcements.create_announcement(admin, %{
          "title" => "Global #{i}",
          "body" => "Hi",
          "scope" => "global"
        })
      end

      student = insert(:account)
      {:ok, {announcements, meta}} = Announcements.list_for_viewer(student, %{"page_size" => 5})

      assert length(announcements) == 5
      assert meta.total_count == 7
    end
  end

  describe "list_for_admin/2" do
    test "admin sees every announcement", %{
      admin: admin,
      my_cohort: my_cohort,
      other_cohort: other_cohort
    } do
      {:ok, _} =
        Announcements.create_announcement(admin, %{
          "title" => "Global",
          "body" => "Hi",
          "scope" => "global"
        })

      {:ok, _} =
        Announcements.create_announcement(admin, %{
          "title" => "Mine",
          "body" => "Hi",
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      {:ok, _} =
        Announcements.create_announcement(admin, %{
          "title" => "Other",
          "body" => "Hi",
          "scope" => "cohort",
          "cohort_id" => other_cohort.id
        })

      {:ok, {_announcements, meta}} = Announcements.list_for_admin(admin, %{})
      assert meta.total_count == 3
    end

    test "instructor sees global + their instructed cohort's, not others'", %{
      admin: admin,
      instructor_account: instructor_account,
      my_cohort: my_cohort,
      other_cohort: other_cohort
    } do
      {:ok, global} =
        Announcements.create_announcement(admin, %{
          "title" => "Global",
          "body" => "Hi",
          "scope" => "global"
        })

      {:ok, mine} =
        Announcements.create_announcement(instructor_account, %{
          "title" => "Mine",
          "body" => "Hi",
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      {:ok, _other} =
        Announcements.create_announcement(admin, %{
          "title" => "Other",
          "body" => "Hi",
          "scope" => "cohort",
          "cohort_id" => other_cohort.id
        })

      {:ok, {announcements, meta}} = Announcements.list_for_admin(instructor_account, %{})

      ids = Enum.map(announcements, & &1.id)
      assert meta.total_count == 2
      assert global.id in ids
      assert mine.id in ids
    end

    test "account without announcements.read sees nothing", %{
      no_perms_account: no_perms_account,
      admin: admin
    } do
      {:ok, _} =
        Announcements.create_announcement(admin, %{
          "title" => "Global",
          "body" => "Hi",
          "scope" => "global"
        })

      {:ok, {_announcements, meta}} = Announcements.list_for_admin(no_perms_account, %{})
      assert meta.total_count == 0
    end
  end
end
