defmodule PhoenixKitManufacturing.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitManufacturing.Errors

  describe "message/1" do
    test "maps known error atoms to human-readable strings" do
      assert Errors.message(:machine_not_found) == "Machine not found."
      assert Errors.message(:machine_type_not_found) == "Machine type not found."
      assert Errors.message(:machine_delete_failed) == "Failed to delete machine."
      assert Errors.message(:type_assignment_failed) =~ "type assignments"
      assert Errors.message(:unexpected) == "An unexpected error occurred."
    end

    test "passes binaries through unchanged" do
      assert Errors.message("custom message") == "custom message"
    end

    test "renders unknown reasons via inspect" do
      assert Errors.message({:weird, :tuple}) =~ "Unexpected error:"
    end
  end
end
