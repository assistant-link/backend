defmodule AssistantLink.Tokens do
  @moduledoc """
  Generates and hashes the secrets the service hands out.

  - Account credentials (`ala_…`) and Link tokens (`alt_…`): 32 random bytes, base64url without padding.
  - Pairing codes: 8 characters of Crockford base32 (no I, L, O, U), shown as `XXXX-XXXX`.

  Only `hash/1` of a secret is stored. Pairing codes are hashed after `normalize_code/1`, so a code
  matches however the user types it.
  """

  @prefixes %{account: "ala_", link: "alt_"}
  @code_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @code_length 8

  @type kind :: :account | :link

  @doc "Generates a new account credential or Link token."
  @spec generate(kind()) :: String.t()
  def generate(kind) do
    Map.fetch!(@prefixes, kind) <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  @doc "Generates a new pairing code in its canonical form (8 characters, no separator)."
  @spec generate_code() :: String.t()
  def generate_code do
    for <<byte <- :crypto.strong_rand_bytes(@code_length)>>, into: "" do
      # 256 is a multiple of the 32-character alphabet, so this is uniform.
      <<Enum.at(@code_alphabet, rem(byte, 32))>>
    end
  end

  @doc """
  Normalizes a pairing code as typed or pasted by a user or agent: ignores case, hyphens, and any
  whitespace (including line breaks and non-breaking spaces), and maps the look-alike letters Crockford
  base32 leaves out (O to 0, I and L to 1).
  """
  @spec normalize_code(String.t()) :: String.t()
  def normalize_code(input) do
    input
    |> String.upcase()
    |> String.replace(~r/[\s\p{Zs}-]/u, "")
    |> String.replace("O", "0")
    |> String.replace(["I", "L"], "1")
  end

  @doc "Formats a canonical pairing code for display, for example `K7QM-2XPA`."
  @spec format_code(String.t()) :: String.t()
  def format_code(<<first::binary-size(4), second::binary-size(4)>>), do: first <> "-" <> second

  @doc "Hashes a secret for storage and lookup."
  @spec hash(String.t()) :: binary()
  def hash(secret), do: :crypto.hash(:sha256, secret)
end
