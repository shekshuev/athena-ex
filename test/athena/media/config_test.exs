defmodule Athena.Media.ConfigTest do
  use ExUnit.Case, async: true

  alias Athena.Media.Config

  test "general file uploads share formats and a 2GB limit" do
    settings = Enum.map(~w(attachment file_assignment personal), &Config.upload_settings/1)
    assert length(Enum.uniq_by(settings, & &1.accept)) == 1

    for setting <- settings do
      assert setting.max_size == 2 * 1024 * 1024 * 1024
      assert ".7z" in setting.accept
      assert ".py" in setting.accept
      assert ".mkv" in setting.accept
    end

    assert Config.upload_settings("video").max_size == hd(settings).max_size
  end
end
