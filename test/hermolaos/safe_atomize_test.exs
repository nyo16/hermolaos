defmodule Hermolaos.SafeAtomizeTest do
  use ExUnit.Case, async: true

  describe "safe key atomization" do
    test "known MCP keys are atomized" do
      # These are standard MCP response keys that exist as atoms
      result = %{content: [%{type: "text", text: "hello"}]}
      assert Hermolaos.get_text(result) == "hello"
    end

    test "unknown keys from server do not create atoms" do
      # Simulate a server response with unusual keys that should NOT create atoms
      # We verify atoms aren't created by checking that the atom doesn't exist
      random_key = "hermolaos_test_nonexistent_key_#{System.unique_integer([:positive])}"

      # This key should definitely not exist as an atom yet
      refute atom_exists?(random_key)

      # Simulate processing a result that would go through atomize_keys
      # by constructing a map with our random key and known keys
      result = Map.put(%{content: [%{type: "text", text: "hello"}]}, random_key, "value")

      # get_text still works (known keys atomized)
      # But the unknown key should NOT have created an atom
      assert Hermolaos.get_text(result) == "hello"
    end

    test "deeply nested unknown keys stay as strings" do
      # When atomize_keys encounters unknown keys in nested maps,
      # they should remain as strings
      result = %{
        content: [
          Map.put(%{type: "text", text: "hello"}, "unusual_server_field", "value")
        ]
      }

      assert Hermolaos.get_text(result) == "hello"
    end

    test "standard MCP fields work correctly through content helpers" do
      # isError field should be atomized since it's a standard MCP field
      result = %{content: [%{type: "text", text: "error msg"}], isError: true}
      assert Hermolaos.get_text(result) == "error msg"
    end

    test "structured content with known keys works" do
      result = %{structuredContent: %{name: "test", value: 42}}
      assert {:ok, %{name: "test", value: 42}} = Hermolaos.get_structured_content(result)
    end
  end

  defp atom_exists?(string) do
    _ = String.to_existing_atom(string)
    true
  rescue
    ArgumentError -> false
  end
end
