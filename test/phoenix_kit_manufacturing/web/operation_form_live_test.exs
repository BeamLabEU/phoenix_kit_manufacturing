defmodule PhoenixKitManufacturing.Web.OperationFormLiveTest do
  # Integration tests — require PostgreSQL, excluded when the DB is
  # unavailable (see test_helper.exs).
  use PhoenixKitManufacturing.LiveCase

  alias PhoenixKitManufacturing.Operations

  defp new_path, do: "/en/admin/manufacturing/machines/operations/new"

  defp edit_path(operation),
    do: "/en/admin/manufacturing/machines/operations/#{operation.uuid}/edit"

  describe "mount" do
    test "renders the new-operation form with unit/base_time_norm_seconds/status fields", %{
      conn: conn
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, new_path())

      assert html =~ "New Operation"
      assert html =~ "operation[name]"
      assert html =~ "operation[unit]"
      assert html =~ "operation[base_time_norm_seconds]"
      assert html =~ "Active"
      assert html =~ "Inactive"
    end

    test "renders the edit form pre-filled from the existing operation", %{conn: conn} do
      {:ok, operation} =
        Operations.create_operation(%{
          name: "Cutting",
          unit: "pcs",
          base_time_norm_seconds: 120
        })

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, edit_path(operation))

      assert html =~ "Edit Cutting"
      assert html =~ ~s(value="Cutting")
      assert html =~ ~s(value="pcs")
      assert html =~ ~s(value="120")
    end

    test "redirects to the operations list with a flash when the uuid doesn't exist", %{
      conn: conn
    } do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: to} = redirect_opts}} =
               live(conn, edit_path(%{uuid: Ecto.UUID.generate()}))

      assert to =~ "manufacturing/machines/operations"

      if flash = redirect_opts[:flash] do
        assert Phoenix.Flash.get(flash, :error) =~ "Operation not found"
      end
    end
  end

  describe "save" do
    test "creates an operation with name/unit/base_time_norm_seconds/status", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("form",
                 operation: %{
                   name: "Cutting",
                   unit: "pcs",
                   base_time_norm_seconds: "120",
                   status: "active"
                 }
               )
               |> render_submit()

      assert to =~ "manufacturing/machines/operations"

      assert [operation] = Operations.list_operations()
      assert operation.name == "Cutting"
      assert operation.unit == "pcs"
      assert operation.base_time_norm_seconds == 120
      assert operation.status == "active"
    end

    test "updates an existing operation in place (no new row created)", %{conn: conn} do
      {:ok, operation} = Operations.create_operation(%{name: "Cutting"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(operation))

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form", operation: %{name: "Cutting", unit: "m", status: "inactive"})
               |> render_submit()

      assert Operations.count_operations() == 1
      updated = Operations.get_operation(operation.uuid)
      assert updated.unit == "m"
      assert updated.status == "inactive"
    end

    test "a blank name fails validation, shows the error, and does not create a row", %{
      conn: conn
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      html =
        view
        |> form("form", operation: %{name: "", unit: "pcs"})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      assert Operations.list_operations() == []
    end

    test "records the actor uuid on the activity log when creating", %{conn: conn} do
      scope = fake_scope()
      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, new_path())

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form", operation: %{name: "Cutting"})
               |> render_submit()

      assert [operation] = Operations.list_operations()

      assert_activity_logged("operation.created",
        actor_uuid: scope.user.uuid,
        resource_uuid: operation.uuid
      )
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages instead of crashing", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      send(view.pid, :some_unrelated_message)
      assert render(view) =~ "New Operation"
    end
  end
end
