require 'benchmark'

current_dir = File.expand_path(File.dirname(__FILE__))

load File.join(current_dir, "fast_git_deploy", "setup.rb")
load File.join(current_dir, "fast_git_deploy", "rollback.rb")

set :scm,            "git"
set :scm_command,    "git"
set(:revision_log)   { "#{deploy_to}/revisions.log" }
set(:version_file)   { "#{current_path}/REVISION" }
set :migrate_target, :current
set :releases,       ['current']
set(:release_path)   { File.join(releases_path, "current") }
set(:releases_path)  { File.join(deploy_to) }
set(:current_path)  { "#{deploy_to}" }

namespace :deploy do
  desc <<-DESC
    Deploy a "cold" application (deploy the app for the first time).
  DESC
  task :cold do
    fast_git_setup.cold
  end

  desc <<-DESC
    Deploy a "warm" application - one which is already running, but was
    setup with deploy:cold provided by capistrano's default tasks
  DESC
  task :warm do
    fast_git_setup.warm
  end

  desc <<-DESC
    Deploy and run pending migrations. This will work similarly to the
    `deploy' task, but will also run any pending migrations (via the
    `deploy:migrate' task) prior to updating the symlink. Note that the
    update in this case it is not atomic, and transactions are not used,
    because migrations are not guaranteed to be reversible.
  DESC
  task :migrations do
    set :migrate_target, :current
    update_code
    symlink
    migrate
    restart
  end

  desc "Just like deploy:migrations, but puts up the maintenance page while migrating"
  task :long do
    set :migrate_target, :current
    deploy.web.disable
    update_code
    symlink
    migrate
    restart
    deploy.web.enable
  end

  desc "Updates code in the repos by fetching and resetting to the latest in the branch"
  task :update_code, :except => { :no_release => true } do
    run [
      "cd #{current_path}",
      "git fetch",
      "git add $(git status --porcelain | grep '??' | awk '{print $2}')",
      "git stash",
      "git reset --hard #{query_revision(branch.chomp) { |cmd| run_locally(cmd) } }",
      "git submodule update --init"
    ].join(" && ")

    finalize_update
  end

  desc <<-DESC
    [internal] Touches up the released code. This is called by update_code
    after the basic deploy finishes. It assumes a Rails project was deployed,
    so if you are deploying something else, you may want to override this
    task with your own environment's requirements.

    This will touch all assets in public/images,
    public/stylesheets, and public/javascripts so that the times are
    consistent (so that asset timestamping works).  This touch process
    is only carried out if the :normalize_asset_timestamps variable is
    set to true, which is the default.
  DESC
  task :finalize_update, :except => { :no_release => true } do
    if fetch(:normalize_asset_timestamps, false)
      stamp = Time.now.utc.strftime("%Y%m%d%H%M.%S")
      asset_paths = %w(images stylesheets javascripts).map { |p| "#{current_path}/public/#{p}" }.join(" ")
      run "find #{asset_paths} -exec touch -t #{stamp} {} ';'; true", :env => { "TZ" => "UTC" }
    end
  end

  desc "Symlink system files & set revision info"
  task :symlink, :except => { :no_release => true } do
    symlink_system_files
    set_revisions
  end

  desc "Symlink system files"
  task :symlink_system_files, :except => { :no_release => true } do
    #noop
  end

  desc "Set the revisions file.  This allows us to go back to previous versions."
  task :set_revisions, :except => { :no_release => true } do
    set_version_file
    update_revisions_log
  end

  task :set_version_file, :except => { :no_release => true } do
    run [
      "cd #{current_path}",
      "#{scm_command} rev-list HEAD | head -n 1 > #{version_file}"
    ].join(" && ")
  end

  task :update_revisions_log, :except => { :no_release => true } do
    run "echo `date +\"%Y-%m-%d %H:%M:%S\"` $USER $(cat #{version_file}) >> #{deploy_to}/revisions.log"
  end

  desc "Do nothing (since we have no releases directory)"
  task :cleanup do
  end

  desc <<-DESC
    Prepares one or more servers for deployment. Before you can use any \
    of the Capistrano deployment tasks with your project, you will need to \
    make sure all of your servers have been prepared with `cap deploy:setup'. When \
    you add a new server to your cluster, you can easily run the setup task \
    on just that server by specifying the HOSTS environment variable:

      $ cap HOSTS=new.server.com deploy:setup

    It is safe to run this task on servers that have already been set up; it \
    will not destroy any deployed revisions or data.
  DESC
  task :setup, :except => { :no_release => true } do
    dirs = [deploy_to]
    sudo "mkdir -p #{dirs.join(' ')}"
    sudo "chown #{deploy_user} #{dirs.join(' ')}"  if fetch(:deploy_user,false)
  end

  desc <<-DESC
    Copies your project and updates the symlink. It does this in a \
    transaction, so that if either `update_code' or `symlink' fail, all \
    changes made to the remote servers will be rolled back, leaving your \
    system in the same state it was in before `update' was invoked. Usually, \
    you will want to call `deploy' instead of `update', but `update' can be \
    handy if you want to deploy, but not immediately restart your application.
  DESC
  task :update do
    transaction do
      update_code
      symlink
    end
  end

  task :restart do
    #noop
  end

  desc <<-DESC
    Deploys your project. This calls both `update' and `restart'. Note that \
    this will generally only work for applications that have already been deployed \
    once. For a "cold" deploy, you'll want to take a look at the `deploy:cold' \
    task, which handles the cold start specifically.
  DESC
  task :default do
    update
    restart
  end
end

# Getting the actual commit id, in case we were passed a tag
# or partial sha or something - it will return the sha if you pass a sha, too
def query_revision(revision)
  raise ArgumentError, "Deploying remote branches is no longer supported.  Specify the remote branch as a local branch for the git repository you're deploying from (ie: '#{revision.gsub('origin/', '')}' rather than '#{revision}')." if revision =~ /^origin\//
  return revision if revision =~ /^[0-9a-f]{40}$/
  command = "git ls-remote #{repository} #{revision}"
  result = yield(command)
  revdata = result.split(/[\t\n]/)
  newrev = nil
  revdata.each_slice(2) do |refs|
    rev, ref = *refs
    if ref.sub(/refs\/.*?\//, '').strip == revision.to_s
      newrev = rev
      break
    end
  end
  raise "Unable to resolve revision for '#{revision}' on repository '#{repository}'." unless newrev =~ /^[0-9a-f]{40}$/
  return newrev
end

# logs the command then executes it locally.
# returns the command output as a string
def run_locally(cmd)
  logger.trace "executing locally: #{cmd.inspect}" if logger
  output_on_stdout = nil
  elapsed = Benchmark.realtime do
    output_on_stdout = `#{cmd}`
  end
  if $?.to_i > 0 # $? is command exit code (posix style)
    raise Capistrano::LocalArgumentError, "Command #{cmd} returned status code #{$?}"
  end
  logger.trace "command finished in #{(elapsed * 1000).round}ms" if logger
  output_on_stdout
end
