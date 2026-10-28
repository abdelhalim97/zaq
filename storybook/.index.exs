defmodule Storybook do
  use Boundary, check: [in: false, out: false]
  use PhoenixStorybook.Index

  def entry("_welcome"), do: [index: -1]
end
