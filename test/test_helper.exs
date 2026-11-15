ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AssistantLink.Repo, :manual)

# A fresh APNs key for each run: tests sign real JWTs, and no key is committed.
apns_key = :public_key.generate_key({:namedCurve, :secp256r1})

Application.put_env(:assistant_link, AssistantLink.Push,
  client: AssistantLink.Push.FakeAPNs,
  key_p8: :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, apns_key)]),
  key_id: "KEY1234567",
  team_id: "TEAM123456",
  topic: "ai.assistantlink.app",
  env: :production
)
