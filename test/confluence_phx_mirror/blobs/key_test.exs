defmodule ConfluencePhxMirror.Blobs.KeyTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Blobs.Key

  describe "attachment/4" do
    test "builds a readable key from confluence identities" do
      assert Key.attachment("ENG", 12_345, 67_890, "Architecture Diagram.svg") ==
               "spaces/ENG/pages/12345/attachments/67890/Architecture-Diagram.svg"
    end

    test "keeps dots that belong to the name" do
      assert Key.attachment("a b", 1, 2, "v1.2.notes.md") ==
               "spaces/a-b/pages/1/attachments/2/v1.2.notes.md"
    end
  end

  describe "space_icon/2" do
    test "takes the extension from the media type, because the path has none" do
      assert Key.space_icon("ENG", "image/png") == "spaces/ENG/icon.png"
      assert Key.space_icon("a b", "image/jpeg; charset=binary") == "spaces/a-b/icon.jpg"
    end

    test "an unknown media type still gets a safe key" do
      assert Key.space_icon("ENG", "application/octet-stream") == "spaces/ENG/icon.bin"
    end
  end

  describe "sanitise_filename/1" do
    test "strips directory traversal and separators" do
      assert Key.sanitise_filename("../../etc/passwd") == "passwd"
      assert Key.sanitise_filename("dir/sub/file.csv") == "file.csv"
      assert Key.sanitise_filename("C:\\Windows\\evil.exe") == "C-Windows-evil.exe"
    end

    test "falls back for empty or odd names" do
      assert Key.sanitise_filename(nil) == "attachment"
      assert Key.sanitise_filename("   ") == "attachment"
      assert Key.sanitise_filename("...") == "attachment"
    end

    test "limits the length but preserves the extension" do
      filename = String.duplicate("a", 400) <> ".pdf"

      assert Key.sanitise_filename(filename) =~ ~r/^a+\.pdf$/
      assert byte_size(Key.sanitise_filename(filename)) <= 120
    end
  end
end
