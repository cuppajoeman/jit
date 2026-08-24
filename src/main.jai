#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "tbx/file";

#if OS == .WINDOWS {
    Windows :: #import "Windows";
} else #if OS_IS_UNIX {
    POSIX :: #import "POSIX";
}

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
    if command == "pull" return run_pull(args);
    if command == "push" return run_push(args);
    if command == "add" return run_add(args);
    if command == "status" return run_status(args);
    if command == "latest" return run_latest(args);
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
  jit pull [args...]              pull and reconcile all nested submodules
  jit push [args...]              refuse parent commits with unpublished submodule commits
  jit add [args...]               refuses files over 50 MiB before staging
  jit status [args...]            clarifies submodule commit direction
  jit latest                      pull this repo and every nested submodule's latest main
  jit commit [args...]            refuses detached HEAD and staged files over 50 MiB
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

run_push :: (args: [] string) -> bool {
    repo_root, root_ok := current_repo_root();
    if !root_ok {
        print("jit push: not inside a Git repository.\n");
        return false;
    }

    for i: 2..args.count - 1 {
        arg := args[i];
        if arg == "--no-recurse-submodules" || begins_with(arg, "--recurse-submodules") {
            print("jit push: submodule recursion options cannot override the publication guard.\n");
            print("Use plain `git push` if you intentionally need to bypass jit's guard.\n");
            return false;
        }
    }

    // Git's check uses remote-tracking refs, so refresh every initialized
    // submodule first. This prevents a deleted/rewritten remote branch from
    // passing merely because a stale origin/* ref still exists locally.
    refresh: [..] string;
    array_add(*refresh, "git");
    array_add(*refresh, "submodule");
    array_add(*refresh, "foreach");
    array_add(*refresh, "--recursive");
    array_add(*refresh, "git fetch --quiet --prune");
    if !run_process_command(refresh) {
        print("jit push: could not refresh every submodule remote; refusing an unverified parent push.\n");
        return false;
    }

    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "push");
    array_add(*command, "--recurse-submodules=check");
    for i: 2..args.count - 1 array_add(*command, args[i]);

    result, output, error := Process.run_command(..command, capture_and_return_output = true);
    if output print("%", output);
    if error write_string(error, to_standard_error = true);

    if result.type == .EXITED && result.exit_code == 0 return true;

    if unpublished_submodule_push_error(output) || unpublished_submodule_push_error(error) {
        print(#string END

jit push: blocked the parent push because it references a submodule commit that
is not published on a submodule remote-tracking branch. A fresh recursive clone
would be unable to check out that commit.

Push each submodule path listed by Git from inside that repository, then return
here and run `jit push` again. jit deliberately checks rather than automatically
pushing submodules, because it cannot safely choose their intended branches or
remotes for you.
END);
    }

    return false;
}

unpublished_submodule_push_error :: (text: string) -> bool {
    return (find_index_from_left(text, "following submodule paths contain changes") >= 0 &&
            find_index_from_left(text, "found on any remote") >= 0) ||
           find_index_from_left(text, "can not be found on any remote") >= 0 ||
           find_index_from_left(text, "cannot be found on any remote") >= 0 ||
           find_index_from_left(text, "not found on any remote") >= 0;
}

run_pull :: (args: [] string) -> bool {
    repo_root, root_ok := current_repo_root();
    if !root_ok {
        print("jit pull: not inside a Git repository.\n");
        return false;
    }

    before := collect_submodule_tree(repo_root);

    pull: [..] string;
    array_add(*pull, "git");
    array_add(*pull, "pull");
    // Pull only the parent here. When the new parent commit references an
    // unpublished submodule commit, Git's recursive pull aborts before the
    // parent can advance and leaves the user with only "not our ref". We do
    // the recursive checkout ourselves below so jit can explain that case.
    array_add(*pull, "--no-recurse-submodules");
    for i: 2..args.count - 1 array_add(*pull, args[i]);
    if !run_process_command(pull) return false;

    if !run_submodule_sync() return false;

    // A recursive update can expose a layout migration one repository at a
    // time. Retry after confirmed cleanup so deeper migrations are handled too.
    for attempt: 1..8 {
        update_ok := run_submodule_update(repo_root);
        current := collect_submodule_tree(repo_root);
        stale := collect_stale_submodules(before, current, repo_root);

        if stale.count == 0 return update_ok;

        targets := build_cleanup_targets(stale, current);
        if targets.count == 0 return update_ok;
        if !confirm_submodule_cleanup(targets, repo_root) {
            print("jit pull: cleanup declined; the submodule update is incomplete.\n");
            return false;
        }
        if !clean_stale_submodules(targets, stale, repo_root) return false;
        if !run_submodule_sync() return false;
    }

    print("jit pull: too many consecutive submodule layout migrations; stopping.\n");
    return false;
}

Submodule_Entry :: struct {
    owner_repo: string;
    name: string;
    local_path: string;
    work_path: string;
    metadata_path: string;
}

Submodule_Cleanup_Target :: struct {
    work_path: string;
    metadata_path: string;
    replaces_old_layout: bool;
}

current_repo_root :: () -> (string, bool) {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "rev-parse");
    array_add(*command, "--show-toplevel");

    ok, output, error := run_capture(command);
    if !ok return "", false;
    return trim_right(output, " \t\r\n"), true;
}

run_submodule_sync :: () -> bool {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "submodule");
    array_add(*command, "sync");
    array_add(*command, "--recursive");
    return run_process_command(command);
}

run_submodule_update :: (repo_root: string) -> bool {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "submodule");
    array_add(*command, "update");
    array_add(*command, "--init");
    array_add(*command, "--recursive");

    result, output, error := Process.run_command(..command, capture_and_return_output = true);
    if output print("%", output);
    if error write_string(error, to_standard_error = true);

    if result.type == .EXITED && result.exit_code == 0 return true;

    if unavailable_pinned_commit_error(output) || unavailable_pinned_commit_error(error) {
        explain_unavailable_pinned_commits(repo_root);
    }
    return false;
}

Missing_Pinned_Submodule :: struct {
    path: string;
    commit: string;
    url: string;
}

unavailable_pinned_commit_error :: (text: string) -> bool {
    return find_index_from_left(text, "not our ref") >= 0 ||
           find_index_from_left(text, "did not contain") >= 0 ||
           find_index_from_left(text, "Direct fetching of that commit failed") >= 0;
}

explain_unavailable_pinned_commits :: (repo_root: string) {
    missing := collect_missing_pinned_submodules(repo_root);

    print("\njit pull: the parent repository was updated, but its exact submodule checkout is unavailable.\n");
    print("A Git parent commit records an exact commit for every submodule, not merely a branch name.\n");

    if missing.count > 0 {
        print("Git could not obtain these required commits:\n");
        for item: missing {
            print("  %\n", item.path);
            print("    required commit: %\n", item.commit);
            if item.url print("    configured remote: %\n", item.url);
        }
    } else {
        print("Git reported that at least one required submodule commit is not available from its remote.\n");
    }

    print(#string END

This normally means the submodule commit was never pushed, was removed by a
history rewrite, or the parent repository recorded the wrong commit. jit cannot
invent that missing history or silently substitute another revision.

To repair the exact checkout, push the listed commits to their submodule remotes
or update the parent repository to reference commits that are published, then run
`jit pull` again.

If you intentionally want every submodule's newest main instead of the parent's
pinned revisions, run `jit latest`. That is a different operation and may leave
the parent repository showing newer submodule commits.
END);
}

collect_missing_pinned_submodules :: (repo_root: string) -> [..] Missing_Pinned_Submodule {
    result: [..] Missing_Pinned_Submodule;
    entries := collect_submodule_tree(repo_root);

    for entry: entries {
        commit, commit_ok := recorded_submodule_commit(entry);
        if !commit_ok continue;
        if submodule_has_commit(entry, commit) continue;

        url, url_ok := declared_submodule_url(entry);
        if !url_ok url = "";

        item := Missing_Pinned_Submodule.{
            path = copy_string(display_path_from_root(entry.work_path, repo_root)),
            commit = copy_string(commit),
            url = copy_string(url),
        };
        array_add(*result, item);
    }

    return result;
}

recorded_submodule_commit :: (entry: Submodule_Entry) -> (string, bool) {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "-C");
    array_add(*command, entry.owner_repo);
    array_add(*command, "rev-parse");
    array_add(*command, tprint("HEAD:%", entry.local_path));

    ok, output, error := run_capture(command);
    if !ok return "", false;
    commit := trim_right(output, " \t\r\n");
    if commit.count != 40 return "", false;
    return commit, true;
}

submodule_has_commit :: (entry: Submodule_Entry, commit: string) -> bool {
    command: [..] string;
    array_add(*command, "git");

    if git_work_tree_is_valid(entry.work_path) {
        array_add(*command, "-C");
        array_add(*command, entry.work_path);
    } else {
        if !entry.metadata_path || !file_exists(entry.metadata_path) return false;
        array_add(*command, tprint("--git-dir=%", entry.metadata_path));
    }

    array_add(*command, "cat-file");
    array_add(*command, "-e");
    array_add(*command, tprint("%^{commit}", commit));
    ok, output, error := run_capture(command);
    return ok;
}

declared_submodule_url :: (entry: Submodule_Entry) -> (string, bool) {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "-C");
    array_add(*command, entry.owner_repo);
    array_add(*command, "config");
    array_add(*command, "-f");
    array_add(*command, ".gitmodules");
    array_add(*command, "--get");
    array_add(*command, tprint("submodule.%.url", entry.name));

    ok, output, error := run_capture(command);
    if !ok return "", false;
    return trim_right(output, " \t\r\n"), true;
}

collect_submodule_tree :: (repo_root: string) -> [..] Submodule_Entry {
    entries: [..] Submodule_Entry;
    visited: [..] string;
    collect_submodules_in_repo(repo_root, *entries, *visited);
    return entries;
}

collect_submodules_in_repo :: (repo: string, entries: *[..] Submodule_Entry, visited: *[..] string) {
    for seen: visited.* {
        if seen == repo return;
    }
    array_add(visited, copy_string(repo));

    immediate := collect_immediate_submodules(repo);
    for entry: immediate {
        array_add(entries, entry);
        if git_work_tree_is_valid(entry.work_path) {
            collect_submodules_in_repo(entry.work_path, entries, visited);
        }
    }
}

collect_immediate_submodules :: (repo: string) -> [..] Submodule_Entry {
    entries: [..] Submodule_Entry;
    gitmodules := jit_path_join(repo, ".gitmodules");
    if !file_exists(gitmodules) return entries;

    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "-C");
    array_add(*command, repo);
    array_add(*command, "config");
    array_add(*command, "--null");
    array_add(*command, "-f");
    array_add(*command, ".gitmodules");
    array_add(*command, "--get-regexp");
    array_add(*command, "^submodule\\..*\\.path$");

    ok, output, error := run_capture(command);
    if !ok && !output return entries;

    records := split_nul(output);
    for record: records {
        key, local_path, record_ok := parse_null_config_record(record);
        if !record_ok continue;

        prefix := "submodule.";
        suffix := ".path";
        if !begins_with(key, prefix) || !ends_with(key, suffix) continue;
        if key.count <= prefix.count + suffix.count continue;

        name := slice(key, prefix.count, key.count - prefix.count - suffix.count);
        work_path := resolve_path(local_path, repo);
        metadata_path, metadata_ok := submodule_metadata_path(repo, name);
        if !metadata_ok metadata_path = "";

        entry := Submodule_Entry.{
            owner_repo = copy_string(repo),
            name = copy_string(name),
            local_path = copy_string(local_path),
            work_path = copy_string(work_path),
            metadata_path = copy_string(metadata_path),
        };
        array_add(*entries, entry);
    }

    return entries;
}

parse_null_config_record :: (record: string) -> (key: string, value: string, ok: bool) {
    newline := find_index_from_left(record, #char "\n");
    if newline <= 0 || newline + 1 >= record.count return "", "", false;
    return slice(record, 0, newline), slice(record, newline + 1, record.count - newline - 1), true;
}

submodule_metadata_path :: (repo: string, module_name_or_path: string) -> (string, bool) {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "-C");
    array_add(*command, repo);
    array_add(*command, "rev-parse");
    array_add(*command, "--git-path");
    array_add(*command, tprint("modules/%", module_name_or_path));

    ok, output, error := run_capture(command);
    if !ok return "", false;
    path := trim_right(output, " \t\r\n");
    return resolve_path(path, repo), true;
}

git_work_tree_is_valid :: (path: string) -> bool {
    if !file_exists(path) return false;

    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "-C");
    array_add(*command, path);
    array_add(*command, "rev-parse");
    array_add(*command, "--is-inside-work-tree");
    ok, output, error := run_capture(command);
    return ok && trim_right(output, " \t\r\n") == "true";
}

collect_stale_submodules :: (before: [] Submodule_Entry, current: [] Submodule_Entry, repo_root: string) -> [..] Submodule_Entry {
    stale: [..] Submodule_Entry;

    for old: before {
        if submodule_work_path_present(current, old.work_path) continue;
        if !file_exists(old.work_path) && (!old.metadata_path || !file_exists(old.metadata_path)) continue;
        add_unique_submodule_entry(*stale, old);
    }

    visited: [..] string;
    collect_stale_local_configs(repo_root, current, *stale, *visited);
    return stale;
}

collect_stale_local_configs :: (repo: string, current: [] Submodule_Entry, stale: *[..] Submodule_Entry, visited: *[..] string) {
    for seen: visited.* {
        if seen == repo return;
    }
    array_add(visited, copy_string(repo));

    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "-C");
    array_add(*command, repo);
    array_add(*command, "config");
    array_add(*command, "--null");
    array_add(*command, "--get-regexp");
    array_add(*command, "^submodule\\..*\\.url$");

    ok, output, error := run_capture(command);
    if ok || output {
        records := split_nul(output);
        for record: records {
            key, url, record_ok := parse_null_config_record(record);
            if !record_ok continue;

            prefix := "submodule.";
            suffix := ".url";
            if !begins_with(key, prefix) || !ends_with(key, suffix) continue;
            if key.count <= prefix.count + suffix.count continue;

            name := slice(key, prefix.count, key.count - prefix.count - suffix.count);
            if submodule_name_present_in_owner(current, repo, name) continue;

            metadata_path, metadata_ok := submodule_metadata_path(repo, name);
            if !metadata_ok metadata_path = "";

            work_path := "";
            if metadata_path && file_exists(metadata_path) {
                show: [..] string;
                array_add(*show, "git");
                array_add(*show, tprint("--git-dir=%", metadata_path));
                array_add(*show, "rev-parse");
                array_add(*show, "--show-toplevel");
                show_ok, show_output, show_error := run_capture(show);
                if show_ok work_path = trim_right(show_output, " \t\r\n");
            }
            // A local config section does not record its old path. Recover it
            // from the submodule repository's core.worktree instead of guessing
            // that the section name and path were identical.
            if !work_path continue;
            if !file_exists(work_path) && (!metadata_path || !file_exists(metadata_path)) continue;

            entry := Submodule_Entry.{
                owner_repo = copy_string(repo),
                name = copy_string(name),
                local_path = copy_string(name),
                work_path = copy_string(work_path),
                metadata_path = copy_string(metadata_path),
            };
            add_unique_submodule_entry(stale, entry);
        }
    }

    for entry: current {
        if entry.owner_repo != repo continue;
        if git_work_tree_is_valid(entry.work_path) {
            collect_stale_local_configs(entry.work_path, current, stale, visited);
        }
    }
}

submodule_work_path_present :: (entries: [] Submodule_Entry, work_path: string) -> bool {
    for entry: entries {
        if entry.work_path == work_path return true;
    }
    return false;
}

submodule_name_present_in_owner :: (entries: [] Submodule_Entry, owner_repo: string, name: string) -> bool {
    for entry: entries {
        if entry.owner_repo == owner_repo && entry.name == name return true;
    }
    return false;
}

add_unique_submodule_entry :: (entries: *[..] Submodule_Entry, candidate: Submodule_Entry) {
    for entry: entries.* {
        if entry.owner_repo == candidate.owner_repo && entry.name == candidate.name && entry.work_path == candidate.work_path return;
    }
    array_add(entries, candidate);
}

build_cleanup_targets :: (stale: [] Submodule_Entry, current: [] Submodule_Entry) -> [..] Submodule_Cleanup_Target {
    targets: [..] Submodule_Cleanup_Target;

    for old: stale {
        target_work_path := old.work_path;
        target_metadata_path := old.metadata_path;
        replacement := false;
        best_parent_length := 0;

        for now: current {
            if !path_is_strictly_inside(old.work_path, now.work_path) continue;
            if now.work_path.count <= best_parent_length continue;
            target_work_path = now.work_path;
            target_metadata_path = now.metadata_path;
            replacement = true;
            best_parent_length = now.work_path.count;
        }

        duplicate := false;
        for target: targets {
            if target.work_path == target_work_path {
                duplicate = true;
                break;
            }
        }
        if duplicate continue;

        target := Submodule_Cleanup_Target.{
            work_path = copy_string(target_work_path),
            metadata_path = copy_string(target_metadata_path),
            replaces_old_layout = replacement,
        };
        array_add(*targets, target);
    }

    return targets;
}

path_is_strictly_inside :: (child: string, parent: string) -> bool {
    if child.count <= parent.count return false;
    if !begins_with(child, parent) return false;
    return child[parent.count] == #char "/" || child[parent.count] == #char "\\";
}

display_path_from_root :: (path: string, repo_root: string) -> string {
    if path_is_strictly_inside(path, repo_root) return slice(path, repo_root.count + 1, path.count - repo_root.count - 1);
    return path;
}

confirm_submodule_cleanup :: (targets: [] Submodule_Cleanup_Target, repo_root: string) -> bool {
    print("\njit pull: the pulled commits changed the submodule layout.\n");
    print("Git left obsolete non-empty directories that block a complete update:\n");
    for target: targets {
        display := display_path_from_root(target.work_path, repo_root);
        if target.replaces_old_layout {
            print("  %  (must be replaced with the new submodule layout)\n", display);
        } else {
            print("  %  (no longer exists as a submodule)\n", display);
        }
    }
    print("\nDelete these directories and their stale Git metadata, then continue? [y/N] ");
    flush_standard_output();

    answer, answer_ok := read_standard_input_line();
    if !answer_ok return false;
    answer = trim_left(trim_right(answer, " \t\r\n"), " \t");
    return equal_nocase(answer, "y") || equal_nocase(answer, "yes");
}

clean_stale_submodules :: (targets: [] Submodule_Cleanup_Target, stale: [] Submodule_Entry, repo_root: string) -> bool {
    for target: targets {
        if !safe_submodule_work_path(target.work_path, repo_root) {
            print("jit pull: refusing unsafe cleanup path '%'.\n", target.work_path);
            return false;
        }
        if target.metadata_path && !safe_submodule_metadata_path(target.metadata_path) {
            print("jit pull: refusing unsafe Git metadata path '%'.\n", target.metadata_path);
            return false;
        }
    }

    for target: targets {
        if file_exists(target.work_path) {
            if !delete_directory(target.work_path) {
                print("jit pull: could not delete obsolete directory '%'.\n", target.work_path);
                return false;
            }
        }
        if target.metadata_path && file_exists(target.metadata_path) {
            if !delete_directory(target.metadata_path) {
                print("jit pull: could not delete stale Git metadata '%'.\n", target.metadata_path);
                return false;
            }
        }
    }

    for old: stale {
        if !git_work_tree_is_valid(old.owner_repo) continue;
        remove_config: [..] string;
        array_add(*remove_config, "git");
        array_add(*remove_config, "-C");
        array_add(*remove_config, old.owner_repo);
        array_add(*remove_config, "config");
        array_add(*remove_config, "--remove-section");
        array_add(*remove_config, tprint("submodule.%", old.name));
        result := Process.run_command(..remove_config, capture_and_return_output = true);
    }

    return true;
}

safe_submodule_work_path :: (path: string, repo_root: string) -> bool {
    if !path || path == "/" || path == repo_root return false;
    return path_is_strictly_inside(path, repo_root);
}

safe_submodule_metadata_path :: (path: string) -> bool {
    if !path || path == "/" return false;
    return find_index_from_left(path, "/modules/") >= 0;
}

read_standard_input_line :: () -> (string, bool) {
    builder: String_Builder;
    read_any := false;

    while true {
        c: u8;
        did_read: s64;
        #if OS == .WINDOWS {
            count: Windows.DWORD;
            input := Windows.GetStdHandle(Windows.STD_INPUT_HANDLE);
            read_ok := Windows.ReadFile(input, *c, 1, *count);
            if !read_ok return builder_to_string(*builder), read_any;
            did_read = count;
        } else #if OS_IS_UNIX {
            did_read = POSIX.read(POSIX.STDIN_FILENO, *c, 1);
        } else {
            #assert(false, "Unsupported platform");
        }

        if did_read <= 0 return builder_to_string(*builder), read_any;
        read_any = true;
        if c == #char "\r" continue;
        if c == #char "\n" return builder_to_string(*builder), true;
        append(*builder, c);
    }

    return builder_to_string(*builder), read_any;
}

flush_standard_output :: () {
    #if OS == .WINDOWS {
        Windows.FlushFileBuffers(Windows.GetStdHandle(Windows.STD_OUTPUT_HANDLE));
    } else #if OS_IS_UNIX {
        POSIX.fflush(null);
    }
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

run_latest :: (args: [] string) -> bool {
    repo_root, root_ok := current_repo_root();
    if !root_ok {
        print("jit latest: not inside a Git repository.\n");
        return false;
    }

    print("jit: updating current repository\n");

    checkout: [..] string;
    array_add(*checkout, "git");
    array_add(*checkout, "-C");
    array_add(*checkout, repo_root);
    array_add(*checkout, "checkout");
    array_add(*checkout, "main");
    if !run_process_command(checkout) return false;

    pull: [..] string;
    array_add(*pull, "git");
    array_add(*pull, "-C");
    array_add(*pull, repo_root);
    array_add(*pull, "pull");
    array_add(*pull, "--no-recurse-submodules");
    if !run_process_command(pull) return false;

    if !all_submodules_initialized() return false;

    latest: [..] string;
    array_add(*latest, "git");
    array_add(*latest, "submodule");
    array_add(*latest, "foreach");
    array_add(*latest, "--recursive");
    array_add(*latest, "git checkout main && git pull && git submodule update --init --recursive");
    return run_process_command(latest);
}

all_submodules_initialized :: () -> bool {
    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "submodule");
    array_add(*command, "status");
    array_add(*command, "--recursive");

    ok, output, error := run_capture(command);
    if !ok {
        print("jit latest: could not inspect the submodule tree.\n");
        if error print("%", error);
        return false;
    }

    at_line_start := true;
    for c: output {
        if at_line_start && c == #char "-" {
            print("jit latest: the submodule tree is not fully initialized. Run `jit pull` first.\n");
            return false;
        }
        at_line_start = c == #char "\n";
    }

    return true;
}

run_commit :: (args: [] string) -> bool {
    if !preflight_commit_has_attached_head() return false;
    if !preflight_staged_file_sizes() return false;
    return run_git_forward(args, start_index = 1);
}

preflight_commit_has_attached_head :: () -> bool {
    repo_root, root_ok := current_repo_root();
    if !root_ok {
        print("jit commit: not inside a Git repository.\n");
        return false;
    }

    command: [..] string;
    array_add(*command, "git");
    array_add(*command, "symbolic-ref");
    array_add(*command, "--quiet");
    array_add(*command, "--short");
    array_add(*command, "HEAD");

    attached, branch, error := run_capture(command);
    if attached return true;

    revision_command: [..] string;
    array_add(*revision_command, "git");
    array_add(*revision_command, "rev-parse");
    array_add(*revision_command, "--short");
    array_add(*revision_command, "HEAD");
    revision_ok, revision, revision_error := run_capture(revision_command);
    if revision_ok revision = trim_right(revision, " \t\r\n");
    else revision = "the current commit";

    print("jit commit: refusing to commit while HEAD is detached at %.\n", revision);
    print(#string END
A detached commit does not belong to a branch and can be left behind when you
checkout another revision. Create a branch at the current commit first:

  git switch -c <branch-name>

Then rerun `jit commit`. If detached mode is intentional, such as during a
rebase, use plain `git commit` to bypass this guard explicitly.
END);
    return false;
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
