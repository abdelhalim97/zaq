const { chromium, firefox, webkit, expect } = require("@playwright/test")
const readline = require("node:readline")
const fs = require("node:fs")
const { waitForLiveViewConnected, waitForLiveViewSettled } = require("./bo")

async function main() {
  const lines = readline.createInterface({ input: process.stdin })[Symbol.asyncIterator]()
  const read = async () => JSON.parse((await lines.next()).value)
  const checkpoint = async stage => {
    console.log(JSON.stringify({ checkpoint: stage }))
    return read()
  }
  const opts = await read()
  const baseURL = process.argv[2]
  const browser = await ({ chromium, firefox, webkit }[opts.engine]).launch()
  const errors = []
  try {
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 } })
    const page = await context.newPage()
    page.on("pageerror", error => errors.push(error.message))
    await login(page, baseURL, opts.username)
    const ready = await checkpoint("ready")
    const result = { ...opts, ...ready }
    await page.goto(`${baseURL}/bo/channels/history/${result.transcript_id}`)
    await waitForLiveViewConnected(page)
    const messages = page.getByRole("region", { name: "Messages", exact: true })
    await expect(messages).toContainText(result.input)
    await expect(messages).not.toContainText("FORBIDDEN_RECIPIENT_ONLY")

    if (opts.mode === "live") {
      await expect(messages).not.toContainText("History answer")
      const completed = await checkpoint("pending-visible")
      Object.assign(result, completed)
      await page.reload()
      await waitForLiveViewConnected(page)
      await expect(messages).toContainText(result.input)
      await expect(messages).toContainText("Active update evidence")
      await expect(messages).toContainText("New input after revocation")
      await expect(messages.getByText(result.answer, { exact: true })).toHaveCount(1)
      await page.getByRole("button", { name: "Manage channel access", exact: true }).click()
      await expect(page.getByText("No current grants", { exact: true })).toBeVisible()
      await page.reload()
      await waitForLiveViewConnected(page)
    }

    if (opts.mode === "recovery") {
      await page.getByRole("button", { name: "Manage channel access", exact: true }).click()
      await expect(page.getByText("No current grants", { exact: true })).toBeVisible()
    }

    for (const width of [390, 1280]) {
      await page.setViewportSize({ width, height: 900 })
      await page.reload()
      await waitForLiveViewConnected(page)
      if (width === 390 && !(await page.locator("#bo-sidebar").getAttribute("class")).split(/\s+/).includes("collapsed")) {
        await page.getByRole("button", { name: "Toggle sidebar", exact: true }).click()
        await expect(page.locator("#bo-sidebar")).toHaveClass(/\bcollapsed\b/)
      }
      await expect(messages).toContainText(result.input)
      await expect(messages.getByText(result.answer, { exact: true })).toHaveCount(1)
      for (const answer of result.public_answers || []) {
        await expect(messages.getByText(answer, { exact: true })).toHaveCount(1)
      }
      if (opts.mode !== "recovery") {
      await page.locator(`button[phx-click='open_message_info'][phx-value-id='${result.answer_id}']`).click()
      await expect(page.locator("[phx-click='close_message_info']")).toBeVisible()
      await expect(page.locator("main")).toContainText("gpt-4.1-mini")
      const displayed = await page.locator("div.flex").evaluateAll(rows => Object.fromEntries(rows.flatMap(row => {
        const spans = Array.from(row.children).filter(el => el.tagName === "SPAN")
        return spans.length === 2 ? [[spans[0].textContent.trim(), spans[1].textContent.trim()]] : []
      })))
      for (const [key, value] of Object.entries(result.measurements)) {
        expect(displayed[key], `persisted ${key}`).toBe(String(value))
      }
      const tool = page.locator("[data-testid^='trace-row-']").filter({ hasText: "Tool Call · Add" })
      await expect(tool).toHaveCount(1)
      await tool.click()
      const trace = JSON.parse(await page.locator("[data-testid^='trace-details-'] pre").textContent())
      expect(trace.name).toBe("add")
      expect(trace.arguments).toEqual({ value: 2, amount: 3 })
      expect(trace.status).toBe("completed")
      expect(trace.response).toEqual(result.tool_response)
      }
      fs.mkdirSync("test/e2e/test-results", { recursive: true })
      await page.screenshot({ path: `test/e2e/test-results/history-${opts.engine}-${opts.strategy}-${opts.mode}-${width}.png` })
    }

    const staffContext = await browser.newContext()
    const staffPage = await staffContext.newPage()
    staffPage.on("pageerror", error => errors.push(error.message))
    await login(staffPage, baseURL, opts.staff_username)
    await staffPage.goto(`${baseURL}/bo/channels/history/${result.transcript_id}`)
    await waitForLiveViewConnected(staffPage)
    await expect(staffPage.getByText("Not authorized", { exact: false })).toBeVisible()
    await expect(staffPage.getByText(result.answer, { exact: true })).toHaveCount(0)
    await expect(staffPage.locator("[data-testid^='trace-row-']")).toHaveCount(0)
    await expect(staffPage.locator("button[phx-click='open_message_info']")).toHaveCount(0)
    expect(errors).toEqual([])
    console.log(`${opts.engine}/${opts.strategy}/${opts.mode}: history journey passed`)
  } finally {
    await browser.close()
  }
}

async function login(page, baseURL, username) {
  await page.goto(`${baseURL}/bo/login`)
  await waitForLiveViewConnected(page)
  await page.locator("[name=username]").fill(username)
  await waitForLiveViewSettled(page)
  await page.locator("[name=password]").fill("StrongPass1!")
  await waitForLiveViewSettled(page)
  await page.locator("#bo-login-form button[type=submit]").click()
  await expect(page).toHaveURL(/\/bo\/dashboard$/)
}

main().then(() => process.exit(0)).catch(error => {
  console.error(error.stack || error)
  process.exit(1)
})
