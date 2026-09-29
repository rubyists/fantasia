defmodule Stokowski.Prompt.Filters do
  @moduledoc false

  def lower(value) when is_list(value),
    do: value |> Enum.join(", ") |> Solid.StandardFilter.downcase()

  def lower(value), do: Solid.StandardFilter.downcase(value)
end
