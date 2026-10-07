defmodule FlowEngine.StaticTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test

  defp call(path) do
    {:ok, engine} = FlowEngine.start_link()

    conn(:get, path)
    |> FlowEngine.HttpRouter.call(engine: engine)
  end

  test "根路径返回旧前端入口页面" do
    response = call("/")

    assert response.status == 200
    assert get_resp_header(response, "content-type") |> List.first() =~ "text/html"
    assert response.resp_body =~ "<!DOCTYPE html>"
  end

  test "静态样式文件返回正确内容类型" do
    response = call("/style.css")

    assert response.status == 200
    assert get_resp_header(response, "content-type") |> List.first() =~ "text/css"
    assert response.resp_body =~ "body"
  end

  test "旧前端 JavaScript 和示例文件可以读取" do
    script = call("/js/config.js")
    example = call("/examples/manifest.json")

    assert script.status == 200
    assert get_resp_header(script, "content-type") |> List.first() =~ "javascript"
    assert script.resp_body =~ "API_BASE"

    assert example.status == 200
    assert get_resp_header(example, "content-type") |> List.first() =~ "json"
    assert Jason.decode!(example.resp_body)
  end

  test "API 路由优先于静态文件处理" do
    response = call("/api/health")

    assert response.status == 200
    assert get_resp_header(response, "content-type") |> List.first() =~ "application/json"
    assert Jason.decode!(response.resp_body)["success"] == true
  end
end
