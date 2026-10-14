defmodule ZaqWeb.Select do
  @moduledoc "Reusable select component — styled dropdown via SearchableSelect with search disabled."

  use Phoenix.Component

  import ZaqWeb.Components.SearchableSelect, only: [searchable_select: 1]
  alias ZaqWeb.Components.DesignSystem.FieldHint

  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :label, :string, default: nil

  attr :label_position, :string,
    default: "block",
    doc: "`inline` or `block` — same as SearchableSelect."

  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :prompt, :string, default: nil
  attr :errors, :list, default: []
  attr :hint, :string, default: nil
  attr :hint_tone, :atom, default: :info, values: [:info, :success, :error]
  attr :hint_id, :string, default: nil
  attr :class, :string, default: nil
  attr :compact, :boolean, default: false

  def select(assigns) do
    ~H"""
    <div class={@class}>
      <.searchable_select
        id={@id || @name}
        name={@name}
        label={@label}
        label_position={@label_position}
        value={@value}
        options={@options}
        empty_label={@prompt || "Select…"}
        searchable={false}
        compact={@compact}
      />
      <FieldHint.field_messages
        errors={@errors}
        hint={@hint}
        hint_tone={@hint_tone}
        hint_id={@hint_id}
      />
    </div>
    """
  end
end
