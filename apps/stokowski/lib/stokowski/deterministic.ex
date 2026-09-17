defmodule Stokowski.Deterministic do
  @moduledoc "Audited deterministic term hashing for the pure reducer boundary."

  @doc "Hash a term with Erlang's deterministic external-term encoding."
  @spec hash(term()) :: binary()
  def hash(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
