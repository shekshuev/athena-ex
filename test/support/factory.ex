defmodule Athena.Factory do
  @moduledoc """
  ExMachina factory module
  """
  use ExMachina.Ecto, repo: Athena.Repo

  alias Athena.Identity.{Account, Role, Profile}
  alias Athena.Media.{File, Quota}

  alias Athena.Content.{
    Course,
    Section,
    Block,
    LibraryBlock,
    CourseShare,
    LibraryBlockShare,
    CourseLibraryBlock,
    Character
  }

  alias Athena.Learning.{
    Cohort,
    Instructor,
    Enrollment,
    Submission,
    SubmissionContent,
    CohortSchedule,
    CohortMembership,
    CohortInstructor,
    BlockProgress
  }

  alias Athena.Messaging.{Conversation, ConversationParticipant, Message, MessageMention}

  def role_factory do
    %Role{
      name: sequence(:name, &"Role #{&1}"),
      permissions: ["courses.read", "courses.update"],
      policies: %{}
    }
  end

  def account_factory do
    %Account{
      login: sequence(:login, &"test_user_#{&1}"),
      password_hash: Argon2.hash_pwd_salt("Password123!"),
      status: :active,
      role: build(:role)
    }
  end

  def profile_factory do
    %Profile{
      first_name: "John",
      last_name: sequence(:last_name, &"Doe #{&1}"),
      owner: build(:account)
    }
  end

  def media_quota_factory do
    %Quota{
      role_id: Ecto.UUID.generate(),
      limit_bytes: 500 * 1024 * 1024
    }
  end

  def media_file_factory do
    %File{
      bucket: Application.get_env(:athena, Athena.Media)[:bucket] || "athena-test",
      key: sequence(:key, &"users/test_owner/files/doc_#{&1}.pdf"),
      original_name: "document.pdf",
      mime_type: "application/pdf",
      size: 1024 * 1024,
      context: :personal,
      owner_id: Ecto.UUID.generate()
    }
  end

  def course_factory do
    %Course{
      title: sequence(:title, &"Course #{&1}"),
      description: "A test course description",
      status: :published,
      owner_id: Ecto.UUID.generate()
    }
  end

  def section_factory do
    %Section{
      id: Ecto.UUID.generate(),
      title: sequence(:title, &"Section #{&1}"),
      order: 0,
      path: %EctoLtree.LabelTree{labels: [Section.uuid_to_ltree(Ecto.UUID.generate())]},
      course: build(:course)
    }
  end

  def block_factory do
    %Block{
      type: :text,
      content: %{"text" => "Default content for the block"},
      order: 1024,
      section: build(:section)
    }
  end

  def library_block_factory do
    %LibraryBlock{
      title: sequence(:title, &"Template #{&1}"),
      type: :text,
      content: %{"text" => "Default content"},
      tags: [],
      owner_id: Ecto.UUID.generate()
    }
  end

  def character_factory do
    %Character{
      name: sequence(:name, &"Character #{&1}"),
      owner_id: Ecto.UUID.generate()
    }
  end

  def instructor_factory do
    %Instructor{
      title: sequence(:title, &"Senior Instructor #{&1}"),
      bio: "An experienced teacher.",
      owner_id: Ecto.UUID.generate()
    }
  end

  def cohort_factory do
    %Cohort{
      name: sequence(:name, &"Cohort #{&1}"),
      description: "A test cohort for integration tests.",
      owner_id: Ecto.UUID.generate()
    }
  end

  def enrollment_factory do
    %Enrollment{
      status: :active
    }
  end

  def submission_factory do
    %Submission{
      account_id: Ecto.UUID.generate(),
      block_id: Ecto.UUID.generate(),
      content: %SubmissionContent{
        type: :text,
        text_answer: "test_answer"
      },
      status: :pending,
      score: 0
    }
  end

  def cohort_membership_factory do
    %CohortMembership{
      account_id: Ecto.UUID.generate(),
      cohort_id: Ecto.UUID.generate()
    }
  end

  def cohort_schedule_factory do
    %CohortSchedule{
      cohort_id: Ecto.UUID.generate(),
      course_id: Ecto.UUID.generate(),
      resource_type: :block,
      resource_id: Ecto.UUID.generate(),
      unlock_at: nil,
      lock_at: nil
    }
  end

  def block_progress_factory do
    %BlockProgress{
      account_id: Ecto.UUID.generate(),
      block_id: Ecto.UUID.generate(),
      status: :completed
    }
  end

  def xp_event_factory do
    %Athena.Gamification.XpEvent{
      account_id: Ecto.UUID.generate(),
      source_type: :block_progress,
      source_id: Ecto.UUID.generate(),
      amount: 10
    }
  end

  def account_stats_factory do
    %Athena.Gamification.AccountStats{
      account_id: Ecto.UUID.generate(),
      total_xp: 0,
      current_streak_weeks: 0,
      longest_streak_weeks: 0,
      current_combo: 0
    }
  end

  def cohort_instructor_factory do
    %CohortInstructor{
      instructor_id: Ecto.UUID.generate(),
      cohort_id: Ecto.UUID.generate()
    }
  end

  def course_share_factory do
    %CourseShare{
      course: build(:course),
      account_id: Ecto.UUID.generate(),
      role: :reader
    }
  end

  def library_block_share_factory do
    %LibraryBlockShare{
      library_block: build(:library_block),
      account_id: Ecto.UUID.generate(),
      role: :reader
    }
  end

  def course_library_block_factory do
    %CourseLibraryBlock{
      course: build(:course),
      library_block: build(:library_block)
    }
  end

  def conversation_factory do
    %Conversation{
      kind: :direct,
      direct_key: sequence(:direct_key, &"acct-#{&1}:acct-#{&1 + 1}")
    }
  end

  def conversation_participant_factory do
    %ConversationParticipant{
      conversation: build(:conversation),
      account_id: Ecto.UUID.generate()
    }
  end

  def message_factory do
    %Message{
      conversation: build(:conversation),
      account_id: Ecto.UUID.generate(),
      kind: :text,
      body: "Hello!"
    }
  end

  def message_mention_factory do
    %MessageMention{
      message: build(:message),
      account_id: Ecto.UUID.generate(),
      matched_text: "@Jane Doe"
    }
  end
end
