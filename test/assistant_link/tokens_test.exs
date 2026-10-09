defmodule AssistantLink.TokensTest do
  use AssistantLink.DataCase, async: true

  import AssistantLink.AccountsFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Scope
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Links.PairingCode
  alias AssistantLink.Tokens

  describe "generate/1" do
    test "account credentials and Link tokens are prefixed 32-byte base64url values" do
      for {kind, prefix} <- [account: "ala_", link: "alt_"] do
        token = Tokens.generate(kind)

        assert <<^prefix::binary-size(4), encoded::binary>> = token
        assert {:ok, bytes} = Base.url_decode64(encoded, padding: false)
        assert byte_size(bytes) == 32
      end
    end

    test "tokens are unique" do
      assert Tokens.generate(:link) != Tokens.generate(:link)
    end
  end

  describe "pairing codes" do
    test "are 8 characters from Crockford base32" do
      for _ <- 1..200 do
        assert Tokens.generate_code() =~ ~r/\A[0-9A-HJKMNP-TV-Z]{8}\z/
      end
    end

    test "are formatted for display as XXXX-XXXX" do
      assert Tokens.format_code("K7QM2XPA") == "K7QM-2XPA"
    end

    test "normalization ignores case, whitespace, and hyphens" do
      for typed <- ["K7QM2XPA", "k7qm-2xpa", "K7QM 2XPA", " k7 qm - 2x pa ", "K7QM-2XPA\n", "\tK7QM 2XPA\r\n"] do
        assert Tokens.normalize_code(typed) == "K7QM2XPA"
      end
    end

    test "normalization maps the letters Crockford base32 leaves out" do
      assert Tokens.normalize_code("o1il-Oo00") == "01110000"
    end
  end

  describe "hash lookup" do
    test "finds a device's scope by its account credential and nothing for other credentials" do
      user = user_fixture()
      {_device, token} = device_fixture(user)

      assert %Scope{user: %{id: user_id}, account: %Account{}} = Accounts.get_scope_by_device_token(token)
      assert user_id == user.id
      assert Accounts.get_scope_by_device_token(Tokens.generate(:account)) == nil
      assert Accounts.get_scope_by_device_token("") == nil
    end

    test "finds a paired Link by its token, with its Assistant" do
      token = Tokens.generate(:link)
      account = Repo.insert!(%Account{})
      assistant = Repo.insert!(%Assistant{account_id: account.id, name: "Hermes", avatar: "avatar-1"})
      link = Repo.insert!(%Link{account_id: account.id, assistant_id: assistant.id, token_hash: Tokens.hash(token)})

      found = Links.get_link_by_token(token)

      assert found.id == link.id
      assert found.assistant.name == "Hermes"
      assert Links.get_link_by_token(Tokens.generate(:link)) == nil
    end

    test "finds a pairing code however it is typed" do
      code = Tokens.generate_code()
      account = Repo.insert!(%Account{})
      assistant = Repo.insert!(%Assistant{account_id: account.id, name: "Hermes", avatar: "avatar-1"})
      link = Repo.insert!(%Link{account_id: account.id, assistant_id: assistant.id})

      Repo.insert!(%PairingCode{
        account_id: account.id,
        link_id: link.id,
        code_hash: Tokens.hash(code),
        expires_at: DateTime.shift(DateTime.utc_now(), minute: 15)
      })

      typed = code |> Tokens.format_code() |> String.downcase()

      assert Repo.get_by(PairingCode, code_hash: Tokens.hash(Tokens.normalize_code(typed))).link_id == link.id
    end
  end
end
