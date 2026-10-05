defmodule Zaq.ConnectorConfig.WidgetSettingsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.ConnectorConfig.WidgetSettings

  test "accepts absent settings and bounded local presentation settings" do
    assert :ok = WidgetSettings.validate(%{})

    assert :ok =
             WidgetSettings.validate(%{
               "display_name" => String.duplicate("a", 200),
               "allowed_domains" => List.duplicate("https://parent.example.test", 100),
               "stylesheet_url" => "/assets/widget.css"
             })
  end

  test "rejects invalid names, origin policies, external assets and malformed settings" do
    for settings <- [
          nil,
          [],
          %{"display_name" => " "},
          %{"display_name" => String.duplicate("a", 201)},
          %{"display_name" => 42},
          %{"allowed_domains" => ["*"]},
          %{"allowed_domains" => List.duplicate("https://parent.example.test", 101)},
          %{"allowed_domains" => "https://parent.example.test"},
          %{"stylesheet_url" => "https://remote.example.test/widget.css"},
          %{"stylesheet_url" => "//remote.example.test/widget.css"},
          %{"stylesheet_url" => "/assets/../private.css"},
          %{"stylesheet_url" => 42}
        ] do
      assert {:error, :invalid_widget_settings} = WidgetSettings.validate(settings)
    end
  end

  property "no settings value can replace the connector-derived widget identity" do
    check all(value <- term()) do
      for key <- ["widget_id", :widget_id] do
        assert {:error, :invalid_widget_settings} = WidgetSettings.validate(%{key => value})
      end
    end
  end

  property "origins are exact authorities, never paths, credentials, queries or fragments" do
    check all(host <- string(:alphanumeric, min_length: 1, max_length: 20)) do
      origin = "https://#{host}.example.test"
      assert :ok = WidgetSettings.validate(%{"allowed_domains" => [origin]})

      for forbidden <- [
            origin <> "/",
            origin <> "/path",
            origin <> "?q=1",
            origin <> "#x",
            "https://user@#{host}.example.test"
          ] do
        assert {:error, :invalid_widget_settings} =
                 WidgetSettings.validate(%{"allowed_domains" => [forbidden]})
      end
    end
  end
end
