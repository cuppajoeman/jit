#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "tbx/file";

Process :: #import "Process";

#scope_module

GITHUB_WARN_LIMIT :: cast(u64) 50 * 1024 * 1024;
GITHUB_HARD_LIMIT :: cast(u64) 100 * 1024 * 1024;
DEFAULT_CHUNK_SIZE :: cast(u64) 50 * 1024 * 1024;
CHUNK_META_NAME :: "meta.txt";

main :: () {
    args := get_command_line_arguments();
    defer array_reset(*args);

    ok := jit_run(args);
    if !ok exit(1);
}

jit_run :: (args: [] string) -> bool {
    if args.count <= 1 {
        print_usage();
        return true;
    }

    command := args[1];
    if command == "help" || command == "--help" || command == "-h" {
        print_usage();
        return true;
    }

    if command == "clone" return run_clone(args);
    if command == "add" return run_add(args);
    if command == "status" return run_status(args);
    if command == "catch-up-submodules" return run_catch_up_submodules(args);
    if command == "commit" return run_commit(args);
    if command == "chunk" || command == "chunk-all" || command == "chunk_all" return run_chunk(args);
    if command == "unchunk" || command == "unchunk-all" || command == "unchunk_all" return run_unchunk(args);

    return run_git_forward(args, start_index = 1);
}

print_usage :: () {
    print(#string END
usage:
  jit <git-command> [args...]
  jit clone <url> [args...]       runs git clone --recurse-submodules -j8 ...
  jit add [args...]               refuses files over 50 MiB before staging
  jit status [args...]            clarifies submodule commit direction
  jit catch-up-submodules         checkout main and pull submodules pointing old
  jit commit [args...]            refuses staged files over 50 MiB
  jit chunk [--size 50M] [files]  split files into <file>.parts directories
  jit chunk-all [--size 50M]      split all files over the size in this tree
  jit unchunk [parts-dirs]        reconstruct files from .parts directories
  jit unchunk-all                 reconstruct all .parts directories in this tree

Chunk sizes accept raw bytes, K, M, or G suffixes using binary units.
END);
}

run_clone :: (args: [] string) -> bool {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "clone");
    array_add(*command, "--recurse-submodules");
    array_add(*command, "-j8");

    for i: 2..args.count - 1 array_add(*command, args[i]);
    return run_process_command(command);
}

run_add :: (args: [] string) -> bool {
    if !preflight_add_file_sizes(args) return false;
    return run_git_forward(args, start_index = 1);
}

run_status :: (args: [] string) -> bool {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "-c");
    array_add(*command, "color.status=always");
    array_add(*command, "status");
    for i: 2..args.count - 1 array_add(*command, args[i]);

    result, output, error := Process.run_command(..command, capture_and_return_output = true);
    if output {
        transformed := rewrite_status_submodule_commit_directions(output);
        print("%", transformed);
    }
    if error write_string(error, to_standard_error = true);

    if result.type == .EXITED return result.exit_code == 0;
    if result.type == .FAILED_TO_LAUNCH print("jit: failed to launch git.\n");
    else print("jit: git status did not exit normally.\n");
    return false;
}

run_catch_up_submodules :: (args: [] string) -> bool {
    old_submodules := collect_changed_submodules_with_direction(.OLD);
    if old_submodules.count == 0 {
        print("jit: no submodules are pointing to old commits.\n");
        return true;
    }

    ok := true;
    for path: old_submodules {
        print("jit: catching up %\n", path);

        checkout: [..] string;
        array_add(*checkout, "git");
        array_add(*checkout, "-C");
        array_add(*checkout, path);
        array_add(*checkout, "checkout");
        array_add(*checkout, "main");
        if !run_process_command(checkout) {
            ok = false;
            continue;
        }

        pull: [..] string;
        array_add(*pull, "git");
        array_add(*pull, "-C");
        array_add(*pull, path);
        array_add(*pull, "pull");
        if !run_process_command(pull) {
            ok = false;
            continue;
        }
    }

    return ok;
}

run_commit :: (args: [] string) -> bool {
    if !preflight_staged_file_sizes() return false;
    return run_git_forward(args, start_index = 1);
}

run_git_forward :: (args: [] string, start_index: int) -> bool {
    command: [..] string;
    array_add(*command, "git");
    for i: start_index..args.count - 1 array_add(*command, args[i]);
    return run_process_command(command);
}

run_process_command :: (command: [] string) -> bool {
    result := Process.run_command(..command);
    if result.type == .EXITED return result.exit_code == 0;
    if result.type == .FAILED_TO_LAUNCH print("jit: failed to launch '%'.\n", command[0]);
    else print("jit: command did not exit normally.\n");
    return false;
}

run_capture :: (command: [] string) -> (ok: bool, output: string, error: string) {
    result, output, error := Process.run_command(..command, capture_and_return_output = true);
    if result.type == .EXITED && result.exit_code == 0 return true, output, error;
    return false, output, error;
}

rewrite_status_submodule_commit_directions :: (status: string) -> string {
    builder: String_Builder;
    start := 0;

    while start < status.count {
        newline := find_index_from_left(status, #char "\n", start);
        line: string;
        include_newline := false;
        if newline < 0 {
            line = slice(status, start, status.count - start);
            start = status.count;
        } else {
            line = slice(status, start, newline - start);
            start = newline + 1;
            include_newline = true;
        }

        rewritten, changed := rewrite_status_line_submodule_direction(line);
        if changed append(*builder, rewritten);
        else append(*builder, line);
        if include_newline append(*builder, "\n");
    }

    return builder_to_string(*builder);
}

rewrite_status_line_submodule_direction :: (line: string) -> (string, bool) {
    plain := strip_ansi(line);
    marker := " (new commits)";
    marker_index := find_index_from_left(plain, marker);
    if marker_index < 0 return line, false;

    modified_index := find_index_from_left(plain, "modified:");
    if modified_index < 0 || modified_index > marker_index return line, false;

    path_start := modified_index + "modified:".count;
    path := slice(plain, path_start, marker_index - path_start);
    path = trim_left(trim_right(path, " \t\r"), " \t");
    if !path return line, false;

    direction, ok := submodule_direction(path);
    if !ok return line, false;

    label := submodule_direction_label_from_direction(direction);
    replacement := colorize_submodule_direction(direction, tprint(" %", label));
    return replace_plain_span_preserving_ansi(line, marker_index, marker.count, replacement), true;
}

strip_ansi :: (text: string) -> string {
    builder: String_Builder;
    i := 0;
    while i < text.count {
        if text[i] == 27 && i + 1 < text.count && text[i + 1] == #char "[" {
            i += 2;
            while i < text.count {
                c := text[i];
                i += 1;
                if c >= #char "@" && c <= #char "~" break;
            }
            continue;
        }

        append(*builder, text[i]);
        i += 1;
    }
    return builder_to_string(*builder);
}

replace_plain_span_preserving_ansi :: (text: string, plain_start: int, plain_count: int, replacement: string) -> string {
    builder: String_Builder;
    plain_index := 0;
    i := 0;
    replaced := false;
    plain_end := plain_start + plain_count;

    while i < text.count {
        if text[i] == 27 && i + 1 < text.count && text[i + 1] == #char "[" {
            ansi_start := i;
            i += 2;
            while i < text.count {
                c := text[i];
                i += 1;
                if c >= #char "@" && c <= #char "~" break;
            }
            append(*builder, slice(text, ansi_start, i - ansi_start));
            continue;
        }

        if !replaced && plain_index == plain_start {
            append(*builder, replacement);
            replaced = true;
        }

        c := text[i];
        if plain_index < plain_start || plain_index >= plain_end append(*builder, c);
        plain_index += 1;
        i += 1;
    }

    if !replaced append(*builder, replacement);
    return builder_to_string(*builder);
}

colorize_like_line :: (line: string, text: string) -> string {
    color, ok := first_ansi_sequence(line);
    if !ok return text;

    builder: String_Builder;
    append(*builder, color);
    append(*builder, text);
    append_ansi_reset(*builder);
    return builder_to_string(*builder);
}

colorize_submodule_direction :: (direction: Submodule_Direction, text: string) -> string {
    if direction != .NEW && direction != .OLD return text;

    builder: String_Builder;
    append_ansi_escape(*builder);
    if direction == .NEW append(*builder, "[34m");
    else append(*builder, "[38;5;208m");
    append(*builder, text);
    append_ansi_reset(*builder);
    return builder_to_string(*builder);
}

first_ansi_sequence :: (text: string) -> (string, bool) {
    i := 0;
    while i + 1 < text.count {
        if text[i] == 27 && text[i + 1] == #char "[" {
            start := i;
            i += 2;
            while i < text.count {
                c := text[i];
                i += 1;
                if c >= #char "@" && c <= #char "~" {
                    return slice(text, start, i - start), true;
                }
            }
            return "", false;
        }
        i += 1;
    }
    return "", false;
}

append_ansi_escape :: (builder: *String_Builder) {
    append(builder, cast(u8) 27);
}

append_ansi_reset :: (builder: *String_Builder) {
    append_ansi_escape(builder);
    append(builder, "[m");
}

Submodule_Direction :: enum {
    SAME;
    NEW;
    OLD;
    DIFFERENT;
}

submodule_direction_label :: (path: string) -> (string, bool) {
    direction, ok := submodule_direction(path);
    if !ok return "", false;

    return submodule_direction_label_from_direction(direction), true;
}

submodule_direction_label_from_direction :: (direction: Submodule_Direction) -> string {
    if direction == .SAME return "(same commit)";
    if direction == .NEW return "(pointing to new commit)";
    if direction == .OLD return "(pointing to old commit)";
    return "(pointing to different commit)";
}

submodule_direction :: (path: string) -> (Submodule_Direction, bool) {
    recorded, recorded_ok := submodule_recorded_commit(path);
    if !recorded_ok return .SAME, false;

    current, current_ok := submodule_current_commit(path);
    if !current_ok return .SAME, false;

    if current == recorded return .SAME, true;

    if submodule_is_ancestor(path, recorded, current) return .NEW, true;
    if submodule_is_ancestor(path, current, recorded) return .OLD, true;

    return .DIFFERENT, true;
}

submodule_recorded_commit :: (path: string) -> (string, bool) {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "ls-files");
    array_add(*command, "-s");
    array_add(*command, "--");
    array_add(*command, path);

    ok, output, error := run_capture(command);
    if !ok return "", false;

    line := trim_right(output, " \t\r\n");
    first_space := find_index_from_left(line, #char " ");
    if first_space < 0 return "", false;
    rest := slice(line, first_space + 1, line.count - first_space - 1);
    second_space := find_index_from_left(rest, #char " ");
    if second_space < 0 return "", false;

    return slice(rest, 0, second_space), true;
}

submodule_current_commit :: (path: string) -> (string, bool) {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "-C");
    array_add(*command, path);
    array_add(*command, "rev-parse");
    array_add(*command, "HEAD");

    ok, output, error := run_capture(command);
    if !ok return "", false;
    return trim_right(output, " \t\r\n"), true;
}

submodule_is_ancestor :: (path: string, maybe_ancestor: string, commit: string) -> bool {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "-C");
    array_add(*command, path);
    array_add(*command, "merge-base");
    array_add(*command, "--is-ancestor");
    array_add(*command, maybe_ancestor);
    array_add(*command, commit);

    result := Process.run_command(..command, capture_and_return_output = true);
    return result.type == .EXITED && result.exit_code == 0;
}

collect_changed_submodules_with_direction :: (target_direction: Submodule_Direction) -> [..] string {
    results: [..] string;

    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "status");
    array_add(*command, "--porcelain=v1");
    array_add(*command, "-z");

    ok, output, error := run_capture(command);
    if !ok return results;

    paths := parse_status_z_changed_paths(output);
    for path: paths {
        if !is_recorded_submodule(path) continue;

        direction, direction_ok := submodule_direction(path);
        if direction_ok && direction == target_direction array_add(*results, copy_string(path));
    }

    return results;
}

is_recorded_submodule :: (path: string) -> bool {
    mode, ok := git_index_mode(path);
    return ok && mode == "160000";
}

git_index_mode :: (path: string) -> (string, bool) {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "ls-files");
    array_add(*command, "-s");
    array_add(*command, "--");
    array_add(*command, path);

    ok, output, error := run_capture(command);
    if !ok return "", false;

    line := trim_right(output, " \t\r\n");
    first_space := find_index_from_left(line, #char " ");
    if first_space < 0 return "", false;
    return slice(line, 0, first_space), true;
}

parse_status_z_changed_paths :: (text: string) -> [..] string {
    paths: [..] string;
    records := split_nul(text);
    skip_next := false;

    for record: records {
        if skip_next {
            skip_next = false;
            continue;
        }

        if record.count < 4 continue;

        path := slice(record, 3, record.count - 3);
        array_add(*paths, path);

        x := record[0];
        if x == #char "R" || x == #char "C" skip_next = true;
    }

    return paths;
}

preflight_add_file_sizes :: (args: [] string) -> bool {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "ls-files");
    array_add(*command, "-z");
    array_add(*command, "--modified");
    array_add(*command, "--others");
    array_add(*command, "--exclude-standard");
    array_add(*command, "--");

    pathspec_seen := false;
    after_separator := false;
    i := 2;
    while i < args.count {
        arg := args[i];
        if after_separator {
            array_add(*command, arg);
            pathspec_seen = true;
        } else if arg == "--" {
            after_separator = true;
        } else if starts_with(arg, "-") {
            if git_add_option_takes_value(arg) && i + 1 < args.count i += 1;
        } else {
            array_add(*command, arg);
            pathspec_seen = true;
        }
        i += 1;
    }

    if !pathspec_seen return true;

    ok, output, error := run_capture(command);
    if !ok {
        print("jit: could not inspect files before add.\n");
        if error print("%", error);
        return false;
    }

    paths := split_nul(output);
    return refuse_large_files(paths, action = "add", subject = "files selected for staging");
}

git_add_option_takes_value :: (arg: string) -> bool {
    if arg == "--pathspec-from-file" return true;
    if arg == "--chmod" return true;
    return false;
}

preflight_staged_file_sizes :: () -> bool {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "diff");
    array_add(*command, "--cached");
    array_add(*command, "--name-only");
    array_add(*command, "-z");

    ok, output, error := run_capture(command);
    if !ok {
        print("jit: could not inspect staged files before commit.\n");
        if error print("%", error);
        return false;
    }

    paths := split_nul(output);
    return refuse_large_files(paths, action = "commit", subject = "staged files");
}

refuse_large_files :: (paths: [] string, action: string, subject: string) -> bool {
    cwd := get_working_directory();
    warning_files: [..] Large_File;
    rejected_files: [..] Large_File;

    for path: paths {
        if !path continue;
        add_large_file_if_needed(path, cwd, *warning_files, *rejected_files);
    }

    if warning_files.count || rejected_files.count {
        print("\njit: refusing % because % exceed GitHub's recommended file size limits.\n", action, subject);

        if warning_files.count {
            print("\nGitHub warns every time you push/fetch files over 50 MiB:\n");
            for file: warning_files print("  %  %\n", readable_byte_size(file.size), file.path);
        }

        if rejected_files.count {
            print("\nGitHub rejects files over 100 MiB entirely:\n");
            for file: rejected_files print("  %  %\n", readable_byte_size(file.size), file.path);
        }

        print("\nRun `jit chunk <file>` for specific files, or `jit chunk-all` to chunk every oversized file in this tree.\n");
        print("Then stage the generated .parts directories and try again.\n");
        return false;
    }

    return true;
}

add_large_file_if_needed :: (path: string, cwd: string, warning_files: *[..] Large_File, rejected_files: *[..] Large_File) {
    full_path := resolve_path(path, cwd);
    modtime, size, size_ok := file_modtime_and_size(full_path);
    if !size_ok return;

    entry := Large_File.{path = copy_string(path), size = cast(u64) size};
    if entry.size > GITHUB_HARD_LIMIT {
        array_add(rejected_files, entry);
    } else if entry.size > GITHUB_WARN_LIMIT {
        array_add(warning_files, entry);
    }
}

Large_File :: struct {
    path: string;
    size: u64;
}

split_nul :: (text: string) -> [..] string {
    parts: [..] string;
    start := 0;
    for i: 0..text.count - 1 {
        if text[i] == 0 {
            array_add(*parts, slice(text, start, i - start));
            start = i + 1;
        }
    }
    if start < text.count array_add(*parts, slice(text, start, text.count - start));
    return parts;
}

run_chunk :: (args: [] string) -> bool {
    chunk_size := DEFAULT_CHUNK_SIZE;
    requested: [..] string;

    i := 2;
    while i < args.count {
        arg := args[i];
        if arg == "--size" || arg == "-s" {
            i += 1;
            if i >= args.count {
                print("jit chunk: missing size after %.\n", arg);
                return false;
            }

            parsed, ok := parse_size(args[i]);
            if !ok || parsed <= 0 {
                print("jit chunk: invalid chunk size '%'.\n", args[i]);
                return false;
            }
            chunk_size = parsed;
        } else {
            array_add(*requested, arg);
        }
        i += 1;
    }

    files := requested;
    if files.count == 0 files = collect_chunk_candidates(".", chunk_size);
    if files.count == 0 {
        print("jit chunk: no files larger than % found.\n", readable_byte_size(chunk_size));
        return true;
    }

    ok := true;
    for file: files {
        if !chunk_file(file, chunk_size) ok = false;
    }
    return ok;
}

run_unchunk :: (args: [] string) -> bool {
    dirs: [..] string;
    for i: 2..args.count - 1 array_add(*dirs, args[i]);
    if dirs.count == 0 dirs = collect_parts_directories(".");

    if dirs.count == 0 {
        print("jit unchunk: no .parts directories found.\n");
        return true;
    }

    ok := true;
    for dir: dirs {
        if !unchunk_directory(dir) ok = false;
    }
    return ok;
}

parse_size :: (text: string) -> (u64, bool) {
    if text.count == 0 return 0, false;
    unit: u64 = 1;
    number := text;
    last := text[text.count - 1];
    if last == #char "K" || last == #char "k" {
        unit = 1024;
        number.count -= 1;
    } else if last == #char "M" || last == #char "m" {
        unit = 1024 * 1024;
        number.count -= 1;
    } else if last == #char "G" || last == #char "g" {
        unit = 1024 * 1024 * 1024;
        number.count -= 1;
    }

    value, ok, remainder := string_to_int(number, 10, u64);
    if !ok || remainder.count != 0 return 0, false;
    return value * unit, true;
}

collect_chunk_candidates :: (dir: string, chunk_size: u64) -> [..] string {
    results: [..] string;
    visitor :: (info: *File_Visit_Info, data: *Chunk_Collect_Data) {
        if info.is_directory {
            if info.short_name == ".git" || ends_with(info.short_name, ".parts") {
                info.descend_into_directory = false;
            }
            return;
        }

        if cast(u64) info.size > data.chunk_size array_add(data.results, copy_string(info.full_name));
    }

    data := Chunk_Collect_Data.{results = *results, chunk_size = chunk_size};
    visit_files(dir, recursive = true, *data, visitor, visit_directories = true);
    return results;
}

Chunk_Collect_Data :: struct {
    results: *[..] string;
    chunk_size: u64;
}

collect_parts_directories :: (dir: string) -> [..] string {
    results: [..] string;
    visitor :: (info: *File_Visit_Info, results: *[..] string) {
        if info.is_directory {
            if info.short_name == ".git" {
                info.descend_into_directory = false;
                return;
            }

            if ends_with(info.short_name, ".parts") {
                meta_path := jit_path_join(info.full_name, CHUNK_META_NAME);
                if file_exists(meta_path) array_add(results, copy_string(info.full_name));
                info.descend_into_directory = false;
            }
        }
    }

    visit_files(dir, recursive = true, *results, visitor, visit_files = false, visit_directories = true);
    return results;
}

chunk_file :: (file_path: string, chunk_size: u64) -> bool {
    modtime, file_size, stat_ok := file_modtime_and_size(file_path);
    if !stat_ok {
        print("jit chunk: not a file: %\n", file_path);
        return false;
    }

    if cast(u64) file_size <= chunk_size {
        print("jit chunk: skipping % (% <= %).\n", file_path, readable_byte_size(cast(u64) file_size), readable_byte_size(chunk_size));
        return true;
    }

    parts_dir := tprint("%.parts", file_path);
    if file_exists(parts_dir) {
        print("jit chunk: output already exists: %\n", parts_dir);
        return false;
    }

    if !make_directory_if_it_does_not_exist(parts_dir, recursive = true) {
        print("jit chunk: could not create %\n", parts_dir);
        return false;
    }

    src, open_ok := file_open(file_path);
    if !open_ok {
        print("jit chunk: could not open %\n", file_path);
        delete_directory(parts_dir);
        return false;
    }
    defer file_close(*src);

    part_count := cast(int) ((cast(u64) file_size + chunk_size - 1) / chunk_size);
    buffer_size: s64 = cast(s64) chunk_size;
    if buffer_size > 8 * 1024 * 1024 buffer_size = 8 * 1024 * 1024;
    buffer := alloc(buffer_size);
    if buffer == null {
        print("jit chunk: could not allocate buffer.\n");
        delete_directory(parts_dir);
        return false;
    }
    defer free(buffer);

    remaining := file_size;
    for part_index: 0..part_count - 1 {
        part_path := jit_path_join(parts_dir, tprint("part_%", formatInt(part_index, 10, minimum_digits = 4)));
        dst, dst_ok := file_open(part_path, for_writing = true, keep_existing_content = false);
        if !dst_ok {
            print("jit chunk: could not create %\n", part_path);
            delete_directory(parts_dir);
            return false;
        }

        bytes_for_part := cast(s64) chunk_size;
        if remaining < bytes_for_part bytes_for_part = remaining;
        left_in_part := bytes_for_part;
        while left_in_part > 0 {
            read_now := buffer_size;
            if left_in_part < read_now read_now = left_in_part;
            read_ok, total_read := file_read(src, buffer, read_now);
            if !read_ok || total_read <= 0 {
                file_close(*dst);
                print("jit chunk: read failed while splitting %.\n", file_path);
                delete_directory(parts_dir);
                return false;
            }
            if !file_write(*dst, buffer, total_read) {
                file_close(*dst);
                print("jit chunk: write failed for %.\n", part_path);
                delete_directory(parts_dir);
                return false;
            }
            left_in_part -= total_read;
        }

        file_close(*dst);
        remaining -= bytes_for_part;
    }

    meta := tprint("original_name=%\npart_size=%\ntotal_parts=%\n", jit_path_basename(file_path), chunk_size, part_count);
    meta_ok := write_entire_file(jit_path_join(parts_dir, CHUNK_META_NAME), meta);
    if !meta_ok {
        print("jit chunk: could not write metadata for %.\n", file_path);
        delete_directory(parts_dir);
        return false;
    }

    file_close(*src);
    if !file_delete(file_path) {
        print("jit chunk: wrote parts but could not remove original %. Remove it before committing.\n", file_path);
        return false;
    }

    print("jit chunk: split % into % parts at % and removed the original.\n", file_path, part_count, parts_dir);
    return true;
}

unchunk_directory :: (parts_dir: string) -> bool {
    meta_path := jit_path_join(parts_dir, CHUNK_META_NAME);
    meta, meta_ok := read_entire_file(meta_path);
    if !meta_ok {
        print("jit unchunk: meta.txt not found in %.\n", parts_dir);
        return false;
    }

    original_name, total_parts, ok := parse_chunk_meta(meta);
    if !ok {
        print("jit unchunk: invalid metadata in %.\n", meta_path);
        return false;
    }

    output_path := jit_path_join(jit_path_dirname(parts_dir), original_name);
    if file_exists(output_path) {
        print("jit unchunk: output already exists: %\n", output_path);
        return false;
    }

    out, out_ok := file_open(output_path, for_writing = true, keep_existing_content = false);
    if !out_ok {
        print("jit unchunk: could not create %\n", output_path);
        return false;
    }
    defer file_close(*out);

    buffer_size: s64 = 8 * 1024 * 1024;
    buffer := alloc(buffer_size);
    if buffer == null {
        print("jit unchunk: could not allocate buffer.\n");
        return false;
    }
    defer free(buffer);

    for part_index: 0..total_parts - 1 {
        part_path := jit_path_join(parts_dir, tprint("part_%", formatInt(part_index, 10, minimum_digits = 4)));
        part, part_ok := file_open(part_path);
        if !part_ok {
            print("jit unchunk: missing part: %\n", part_path);
            return false;
        }

        while true {
            read_ok, total_read := file_read(part, buffer, buffer_size);
            if !read_ok {
                file_close(*part);
                print("jit unchunk: read failed for %.\n", part_path);
                return false;
            }
            if total_read == 0 break;
            if !file_write(*out, buffer, total_read) {
                file_close(*part);
                print("jit unchunk: write failed for %.\n", output_path);
                return false;
            }
        }
        file_close(*part);
    }

    file_close(*out);
    if !delete_directory(parts_dir) {
        print("jit unchunk: reconstructed %, but could not remove %.\n", output_path, parts_dir);
        return false;
    }

    print("jit unchunk: reconstructed % and removed %.\n", output_path, parts_dir);
    return true;
}

parse_chunk_meta :: (meta: string) -> (string, int, bool) {
    original_name, name_ok := chunk_meta_value(meta, "original_name=");
    total_parts_text, parts_text_ok := chunk_meta_value(meta, "total_parts=");
    if !name_ok || !parts_text_ok return "", 0, false;

    total_parts := 0;
    for c: total_parts_text {
        if c < #char "0" || c > #char "9" return "", 0, false;
        total_parts = total_parts * 10 + cast(int)(c - #char "0");
    }

    return original_name, total_parts, original_name.count > 0 && total_parts > 0;
}

chunk_meta_value :: (meta: string, key: string) -> (string, bool) {
    start := find_index_from_left(meta, key);
    if start < 0 return "", false;
    start += key.count;

    end := start;
    while end < meta.count && meta[end] != #char "\n" && meta[end] != #char "\r" end += 1;
    return slice(meta, start, end - start), true;
}

jit_path_join :: (a: string, b: string) -> string {
    if a.count == 0 || a == "." return b;
    last := a[a.count - 1];
    if last == #char "/" || last == #char "\\" return tprint("%%", a, b);
    return tprint("%/%", a, b);
}

jit_path_basename :: (path: string) -> string {
    last := -1;
    for i: 0..path.count - 1 {
        if path[i] == #char "/" || path[i] == #char "\\" last = i;
    }
    if last < 0 return path;
    return slice(path, last + 1, path.count - last - 1);
}

jit_path_dirname :: (path: string) -> string {
    last := -1;
    for i: 0..path.count - 1 {
        if path[i] == #char "/" || path[i] == #char "\\" last = i;
    }
    if last < 0 return ".";
    if last == 0 return slice(path, 0, 1);
    return slice(path, 0, last);
}
