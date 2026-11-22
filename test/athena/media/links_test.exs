defmodule Athena.Media.LinksTest do
  use Athena.DataCase, async: true

  import Athena.Factory
  alias Athena.Media

  test "audit reports direct saved storage links without changing content or exposing signatures" do
    user = insert(:account)
    config = Application.get_env(:athena, Media)
    s3 = ExAws.Config.new(:s3)
    host = config[:public_host] || s3.host
    port = config[:public_port] || s3.port
    scheme = config[:public_scheme] || s3.scheme
    url = "#{scheme}#{host}:#{port}/#{config[:bucket]}/old.png?X-Amz-Signature=do-not-print"
    block = insert(:block, content: %{"url" => url})
    library = insert(:library_block, content: %{"image" => %{"src" => url}})
    submission = insert(:submission, account_id: user.id, content: %{"file_urls" => [url]})
    profile = insert(:profile, owner: user, avatar_url: url)
    insert(:block, content: %{"url" => "/media/courses/a/good.png"})
    insert(:block, content: %{"url" => "https://external.example/image.png"})

    result = Media.audit_storage_links()

    assert %{
             content: %{blocks: [%{id: block_id, direct_links: 1}], library: [%{id: library_id}]},
             submissions: [%{id: submission_id}],
             profiles: [%{id: profile_id}]
           } = result

    assert {block_id, library_id, submission_id, profile_id} ==
             {block.id, library.id, submission.id, profile.id}

    refute inspect(result) =~ "do-not-print"
    assert Repo.get!(Athena.Content.Block, block.id).content == block.content
  end
end
