defmodule AssistantLinkWeb.PageHTML do
  @moduledoc """
  Pages rendered by `AssistantLinkWeb.PageController`, one per template
  in the `page_html` directory.
  """
  use AssistantLinkWeb, :html

  embed_templates "page_html/*"
end
