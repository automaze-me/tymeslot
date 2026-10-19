defmodule Tymeslot.ThemeCustomizations.PageUploadsTest do
  # Swaps the global upload directory, so it cannot run concurrently.
  use Tymeslot.DataCase, async: false

  @moduletag :themes

  import Tymeslot.Factory

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Storage

  setup do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_uploads_#{System.unique_integer([:positive])}")

    original_root = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_root)

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original_root)
      File.rm_rf(upload_root)
    end)

    profile = insert(:profile)
    page = insert(:booking_page, profile: profile)
    %{profile: profile, page: page}
  end

  defp attach!(scope, filename) do
    temp = MediaFixtures.temp_copy!("gps.webp")

    {:ok, customization} =
      ThemeCustomizations.attach_asset(scope, "1", :background_image_path, %{
        path: temp,
        filename: filename
      })

    customization.settings["background_image_path"]
  end

  test "a page's upload never replaces or deletes the profile's file of the same name", ctx do
    profile_path = attach!(ctx.profile.id, "bg.webp")
    page_path = attach!({ctx.profile.id, ctx.page.id}, "bg.webp")

    refute profile_path == page_path

    assert %{booking_page_id: page_id} =
             ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "1")

    assert page_id == ctx.page.id

    assert :ok = ThemeCustomizations.delete_page_customizations(ctx.page.id)

    assert File.exists?(Storage.build_theme_file_path(profile_path))
    refute File.exists?(Storage.build_theme_file_path(page_path))
  end
end
