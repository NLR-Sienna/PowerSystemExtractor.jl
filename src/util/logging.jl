# ==============================================================================
# File Logging Wrapper
# ==============================================================================

"""
Runs `f()` while teeing all `@info`, `@warn`, and `@error` messages to both the console
and `log_file` (if provided) using `InfrastructureSystems.MultiLogger`.
"""
function _with_optional_logfile(f::Function, log_file::Union{Nothing, String})
    isnothing(log_file) && return f()

    mkpath(dirname(abspath(log_file)))
    open(log_file, "w") do io
        console_logger = Logging.ConsoleLogger(stderr, Logging.Info)
        file_logger = IS.FileLogger(io, Logging.Info)
        multi_logger = IS.MultiLogger([console_logger, file_logger])

        println(io, "=== Regional System Extraction Log ($(Dates.now())) ===\n")
        try
            return Logging.with_logger(multi_logger) do
                f()
            end
        finally
            flush(io)
        end
    end
end