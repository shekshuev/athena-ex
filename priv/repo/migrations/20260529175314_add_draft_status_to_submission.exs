defmodule Athena.Repo.Migrations.AddDraftStatusToSubmissions do
  use Ecto.Migration

  def up do
    create index(:submissions, [:account_id, :block_id],
             where: "status != 'draft'",
             name: :submissions_active_account_block_idx
           )

    create index(:submissions, [:cohort_id, :block_id],
             where: "status != 'draft' AND cohort_id IS NOT NULL",
             name: :submissions_active_cohort_block_idx
           )

    create index(:submissions, [:account_id, :block_id],
             where: "status = 'draft'",
             name: :submissions_draft_account_block_idx
           )

    create index(:submissions, [:cohort_id, :block_id],
             where: "status = 'draft' AND cohort_id IS NOT NULL",
             name: :submissions_draft_cohort_block_idx
           )
  end

  def down do
    drop index(:submissions, [:account_id, :block_id],
           name: :submissions_active_account_block_idx
         )

    drop index(:submissions, [:cohort_id, :block_id], name: :submissions_active_cohort_block_idx)
    drop index(:submissions, [:account_id, :block_id], name: :submissions_draft_account_block_idx)
    drop index(:submissions, [:cohort_id, :block_id], name: :submissions_draft_cohort_block_idx)
  end
end
