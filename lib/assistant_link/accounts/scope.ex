defmodule AssistantLink.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `AssistantLink.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.User

  @typedoc """
  A user acting in one of their accounts. Data is scoped by `scope.account.id`. Get one from
  `AssistantLink.Accounts`, which builds it only from a membership.
  """
  @type t :: %__MODULE__{user: User.t(), account: Account.t()}

  defstruct user: nil, account: nil
end
