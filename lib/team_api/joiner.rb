# @author Mike Bland (michael.bland@gsa.gov)

require_relative 'api'
require 'hash-joiner'

module TeamApi
  class UnknownSnippetUsernameError < StandardError
  end

  # Joins the data from collections into +site.data+. Also filters out private
  # data when +site.config[+'public'] is +true+ (aka "public mode").
  class Joiner
    # Executes all of the steps to join the different data sources into
    # +site.data+ and filters out private data when in public mode.
    #
    # +site+:: Jekyll site data object
    def self.join_data(site)
      impl = JoinerImpl.new site
      impl.restructure_team_data!
      impl.init_team_data site.data['team']
      impl.promote_or_remove_data
      impl.join_project_data
      Api.add_self_links site
      impl.join_snippet_data
    end
  end

  class TeamIndexer
    def initialize(data)
      @team = (data || {}).dup
    end

    def team
      @team || {}
    end

    def create_indexes
      team_by_email
      team_by_github
      team_by_deprecated_name
    end

    # Returns an index of team member usernames keyed by email address.
    def team_by_email
      @team_by_email ||= team_index_by_field 'email'
    end

    # Returns an index of team member usernames keyed by GitHub username.
    def team_by_github
      @team_by_github ||= team_index_by_field 'github'
    end

    # Returns an index of team member usernames keyed by deprecated names.
    def team_by_deprecated_name
      @team_by_deprecated_name ||= team_index_by_field 'deprecated_name'
    end

    # Returns an index of team member usernames keyed by a particular field.
    def team_index_by_field(field)
      team_members.map do |member|
        value = member[field]
        value = member['private'][field] if value.nil? && member['private']
        [value.downcase, member['name'].downcase] unless value.nil?
      end.compact.to_h
    end

    # Returns the list of team members, with site.data['team']['private']
    # members included.
    def team_members
      @team_members ||= team.map { |key, value| value unless key == 'private' }
        .compact
        .concat((team['private'] || {}).values)
    end

    def team_member_key_by_type(ref)
      (ref.is_a? String) ? ref : (ref['id'] || ref['email'] || ref['github'] || ref['deprecated_name'])
    end

    def team_member_key(ref)
      key = team_member_key_by_type(ref).downcase
      team_by_email[key] || team_by_github[key] || team_by_deprecated_name[key] || key
    end

    def team_member_from_reference(reference)
      key = team_member_key reference

      if team['private']
        team[key] || team['private'][key]
      else
        team[key]
      end
    end

    def team_member_is_private(reference)
      key = team_member_key(reference).downcase
      team['private'] && team['private'][key]
    end
  end

  # Implements Joiner operations.
  class JoinerImpl
    attr_reader :site, :data, :public_mode, :team_indexer

    # +site+:: Jekyll site data object
    def initialize(site)
      @site = site
      @data = site.data
      @public_mode = site.config['public']
    end

    # Jekyll seems to be removing non-alpha characters from the team member
    # names, causing the TeamIndexer to not be able to find any team member
    # matches. This changes all of the team member keys back to what we expect.
    def restructure_team_data!
      if !site.data['team'].nil? && site.data['team'].respond_to?(:keys)
        site.data['team'].keys.each do |key|
          site.data['team'][site.data['team'][key]['name']] = site.data['team'].delete(key)
        end
      end
    end

    def init_team_data(data)
      @team_indexer = TeamIndexer.new data
      team_indexer.create_indexes
    end

    def promote_or_remove_data
      private_data_method = public_mode ? :remove_data : :promote_data
      HashJoiner.send private_data_method, data, 'private'
    end

    def join_project_data
      # A little bit of project data munging. Can go away after the .about.yml
      # convention takes hold, hopefully.
      projects = (data['projects'] ||= {})
      projects.delete_if { |_, p| p['status'] == 'Hold' } if @public_mode
      projects.values.each do |p|
        errors = p['errors'] || []
        join_team_list p['team'], errors
        store_project_errors p, errors unless errors.empty?
      end
    end

    def store_project_errors(project, errors)
      project['errors'] = errors
      name = project['github'][0] if project['github']
      name ||= project['name']
      data['errors'][name] = errors
    end

    def should_exclude_member(reference)
      @public_mode && team_indexer.team_member_is_private(reference)
    end

    def get_canonical_reference(reference, errors)
      member = team_indexer.team_member_from_reference reference

      if member.nil?
        errors << 'Unknown Team Member: ' +
          team_indexer.team_member_key(reference)
        nil
      elsif should_exclude_member(reference)
        nil
      else
        member['name'].downcase
      end
    end

    # Replaces each member of team_list with a key into the team hash.
    # Values can be:
    # - Strings that are already team hash keys
    # - Strings that are email addresses
    # - Strings that are GitHub usernames
    # - Hashes that contain an 'email' property
    # - Hashes that contain a 'github' property
    def join_team_list(team_list, errors)
      (team_list || []).map! do |reference|
        get_canonical_reference reference, errors
      end.compact! || []
    end

    SNIPPET_JOIN_FIELDS = %w(name full_name first_name last_name self)

    # Joins snippet data into +site.data[+'snippets'] and filters out snippets
    # from team members not appearing in +site.data[+'team'] or
    # +team_by_email+.
    def join_snippet_data
      raw_snippets = data['snippets']
      return if raw_snippets.nil?
      data['snippets'] = raw_snippets.map do |timestamp, snippets|
        joined = snippets.map { |snippet| join_snippet snippet }
          .compact.each { |i| i.delete 'username' }
        [timestamp, joined] unless joined.empty?
      end.compact.to_h
    end

    def join_snippet(snippet)
      username = snippet['username']
      member = team_indexer.team_member_from_reference username

      if member.nil?
        fail UnknownSnippetUsernameError, username unless public_mode
      else
        member = member.select { |k, _| SNIPPET_JOIN_FIELDS.include? k }
        snippet.merge member
      end
    end
  end
end
