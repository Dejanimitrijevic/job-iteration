# frozen_string_literal: true

require "test_helper"

require_relative "../support/jobs"

class ResqueIntegrationTest < ActiveSupport::TestCase
  setup do
    @original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :resque
  end

  teardown do
    ActiveJob::Base.queue_adapter = @original_adapter
  end

  test "interrupts the job" do
    IterationJob.perform_later

    start_resque_and_wait

    assert_equal 1, queue_size
    job_args = jobs_in_queue.first.fetch("args")
    assert_equal 0, job_args.dig(0, "cursor_position")
    assert_equal 1, job_args.dig(0, "times_interrupted")

    start_resque_and_wait

    assert_equal 1, queue_size
    job_args = jobs_in_queue.first.fetch("args")
    assert_equal 2, job_args.dig(0, "cursor_position")
    assert_equal 2, job_args.dig(0, "times_interrupted")

    TerminateJob.perform_later
    start_resque_and_wait

    assert_equal 0, queue_size
  end

  test "unserializable corruption is prevented" do
    # Resque serializes cursors as JSON, but not all objects are serializable.
    #     time   = Time.at(0).utc   # => 1970-01-01 00:00:00 UTC
    #     json   = JSON.dump(time)  # => "\"1970-01-01 00:00:00 UTC\""
    #     string = JSON.parse(json) # => "1970-01-01 00:00:00 UTC"
    # We serialized a Time, but it was deserialized as a String.
    TimeCursorJob.perform_later
    TerminateJob.perform_later
    start_resque_and_wait

    assert_equal(
      JobIteration::Iteration::CursorError.name,
      failed_job_error_class_name,
    )
  end

  private

  def start_resque_and_wait
    pid = nil
    Dir.chdir("test/support/resque") do
      pid = spawn(resque_env, "bundle exec rake resque:work")
    end
  ensure
    Process.wait(pid) if pid
  end

  def resque_env
    {
      "QUEUE" => "default",
      "VVERBOSE" => "true",
      "VERBOSE" => "true",
      "GRACEFUL_TERM" => "true",
      "FORK_PER_JOB" => "false",
    }
  end

  def queue_size
    Resque.queue_sizes.fetch("default")
  end

  def jobs_in_queue
    Resque.redis.lrange("queue:default", 0, -1).map { |payload| JSON.parse(payload) }
  end

  def failed_job_error_class_name
    Resque::Failure.backend.all&.fetch("exception")
  end
end
