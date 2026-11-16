defmodule AssistantLink.Push.ProviderToken do
  @moduledoc """
  The APNs provider token: an ES256 JWT for the team, signed with the `.p8` key. Each node signs a new
  one every 50 minutes, since APNs refuses one older than an hour or replaced more often than every 20.
  """
  @lifetime_seconds 50 * 60

  @spec get(keyword()) :: String.t()
  def get(config) do
    key = {__MODULE__, Keyword.fetch!(config, :key_id), Keyword.fetch!(config, :team_id)}
    now = System.system_time(:second)

    case :persistent_term.get(key, nil) do
      {token, issued_at} when now - issued_at < @lifetime_seconds ->
        token

      _missing_or_old ->
        token = sign(config, now)
        :persistent_term.put(key, {token, now})
        token
    end
  end

  defp sign(config, issued_at) do
    input = encode(%{alg: "ES256", kid: config[:key_id]}) <> "." <> encode(%{iss: config[:team_id], iat: issued_at})
    [entry] = :public_key.pem_decode(Keyword.fetch!(config, :key_p8))
    der = :public_key.sign(input, :sha256, :public_key.pem_entry_decode(entry))
    # JWS wants the raw r and s, not DER.
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> Base.url_encode64(<<r::256, s::256>>, padding: false)
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)
end
