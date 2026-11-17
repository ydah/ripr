# frozen_string_literal: true

require "timeout"
require "ripr/engine/child" if File.file?(File.expand_path("../lib/ripr/engine/child.rb", __dir__))
require "ripr/core/classifier" if File.file?(File.expand_path("../lib/ripr/core/classifier.rb", __dir__))

RSpec.describe "mutation execution" do
  it "reports worker progress from the parent as each task finishes" do
    updates = []
    parent = Process.pid
    results = Ripr::Engine::Child.batch([1, 2], jobs: 2, timeout: ->(_) { 1000 },
                                                on_complete: ->(done, total) { updates << [Process.pid, done, total] }) do |task|
      { "value" => task }
    end
    expect(results.map(&:first).sort).to eq([1, 2])
    expect(updates).to eq([[parent, 0, 2], [parent, 1, 2], [parent, 2, 2]])
  end

  it "isolates state and drains results larger than a pipe buffer" do
    result = Ripr::Engine::Child.call(timeout_ms: 1000) { { "value" => "x" * 200_000 } }
    expect(result.fetch("value").size).to eq(200_000)
  end

  it "kills timed out children and reports abrupt exits" do
    result = Ripr::Engine::Child.call(timeout_ms: 30) { loop { sleep 1 } }
    expect(result.fetch("status")).to eq("timeout")
    result = Ripr::Engine::Child.call(timeout_ms: 1000) { exit! 9 }
    expect(result.fetch("status")).to eq("error")
  end

  it "counts survivors and errors in the score denominator" do
    results = %w[killed timeout not_reached not_infected not_detected error accepted invalid static].map { |s| { "status" => s } }
    summary = Ripr::Core::Classifier.summary(results)
    expect(summary.fetch("score")).to eq(33.3)
    expect(summary.fetch("survived")).to eq(3)
  end

  it "collects a completed worker even when its grandchild keeps the pipe open" do
    result = Ripr::Engine::Child.call(timeout_ms: 100) do
      fork do
        sleep 5
        exit! 0
      end
      { "success" => true }
    end
    expect(result).to eq("success" => true)
  end
end
