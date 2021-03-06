# encoding: utf-8
module Sponges
  class Handler
    extend Forwardable

    attr_reader :supervisor, :queue, :notifier

    def initialize(supervisor)
      @supervisor = supervisor
      @queue, @notifier = IO.pipe
      at_exit do
        for_supervisor do
          Sponges.logger.info "Supervisor exits."
        end
      end
    end

    def push(signal)
      @notifier.puts(signal)
    end

    def call
      Thread.new do
        while signal = @queue.gets do
          if Sponges::SIGNALS.include?(signal = find_signal(signal.chomp))
            send "handler_#{signal.to_s.downcase}", signal
          end
        end
      end
    end

    def_delegators :@supervisor, :store, :fork_children, :name, :children_name

    private

    def for_supervisor
      yield if Process.pid == store.supervisor_pid
    end

    def find_signal(signal)
      return signal.to_sym if signal =~ /\D/
      if signal = Signal.list.find {|k,v| v == signal.to_i }
        signal.first.to_sym
      end
    end

    def handler_ttin(signal)
      for_supervisor do
        Sponges.logger.warn "Supervisor increment child's pool by one."
        fork_children
      end
    end

    def handler_ttou(signal)
      for_supervisor do
        Sponges.logger.warn "Supervisor decrement child's pool by one."
        if store.children_pids.first
          kill_one(store.children_pids.first, :HUP)
          store.delete_children(store.children_pids.first)
        else
          Sponges.logger.warn "No more child to kill."
        end
      end
    end

    def handler_chld(signal)
      for_supervisor do
        return if stopping?
        store.children_pids.each do |pid|
          begin
            if dead = Process.waitpid(pid.to_i, Process::WNOHANG)
              store.delete_children dead
              Sponges.logger.warn "Child #{dead} died. Restarting a new one..."
              Sponges::Hook.on_chld
              fork_children
            end
          rescue Errno::ECHILD => e
            # Don't panic
          end
        end
      end
    end

    def handler_int(signal)
      for_supervisor do
        @stopping = true
        Sponges.logger.info "Supervisor received #{signal} signal."
        kill_them_all(signal) and shutdown
      end
    end

    alias handler_quit handler_int
    alias handler_term handler_int
    alias handler_hup handler_int

    def kill_them_all(signal)
      store.children_pids.map do |pid|
        Thread.new { kill_one(pid.to_i, signal) }
      end.each &:join
    end

    def kill_one(pid, signal)
      begin
        Process.kill signal, pid
        Process.waitpid pid
        Sponges.logger.info "Child #{pid} receive a #{signal} signal."
      rescue Errno::ESRCH, Errno::ECHILD, SignalException => e
        # Don't panic
      end
    end

    def shutdown
      Process.waitall
      Sponges.logger.info "Children shutdown complete. Exiting..."
      store.clear(name)
      exit
    rescue Errno::ESRCH, Errno::ECHILD, SignalException => e
      # Don't panic
    end

    def fork_children
      name = children_name
      pid = Sponges::Worker.new(supervisor, name).call
      Sponges.logger.info "Supervisor create a child with #{pid} pid."
      store.add_children pid
    end

    def stopping?
      @stopping
    end
  end
end
