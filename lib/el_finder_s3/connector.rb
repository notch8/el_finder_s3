require 'logger'
require 'base64'

module ElFinderS3

  # Represents ElFinder connector on Rails side.
  class Connector

    # Valid commands to run.
    # @see #run
    VALID_COMMANDS = %w[archive duplicate put file ls tree extract mkdir mkfile open paste ping get rename resize rm tmb upload]

    attr_reader :adapter

    # Default options for instances.
    # @see #initialize
    DEFAULT_OPTIONS = {
      :mime_handler => ElFinderS3::MimeType,
      :image_handler => ElFinderS3::Image,
      :original_filename_method => lambda { |file| file.original_filename.respond_to?(:force_encoding) ? file.original_filename.force_encoding('utf-8') : file.original_filename },
      :disabled_commands => %w(archive duplicate extract resize tmb),
      :allow_dot_files => true,
      :upload_max_size => '50M',
      :name_validator => lambda { |name| name.strip != '.' && name =~ /^[^\x00-\x1f\\?*:"><|\/]+$/ },
      :upload_file_mode => 0644,
      :archivers => {},
      :extractors => {},
      :home => 'Home',
      :default_perms => {:read => true, :write => true, :locked => false, :hidden => false},
      :perms => [],
      :thumbs => false,
      :thumbs_directory => '.thumbs',
      :thumbs_size => 48,
      :thumbs_at_once => 5,
    }

    # Initializes new instance.
    # @param [Hash] options Instance options. :url and :server options are required.
    # @option options [String] :url Entry point of ElFinder router.
    # @option options [String] :server A hash containing the :host, :username, :password, and, optionally, :port to connect to
    # @see DEFAULT_OPTIONS
    def initialize(options)
      @options = DEFAULT_OPTIONS.merge(options)

      raise(ArgumentError, 'Missing required :url option') unless @options.key?(:url)
      raise(ArgumentError, 'Missing required :server option') unless @options.key?(:server)
      raise(ArgumentError, 'Mime Handler is invalid') unless mime_handler.respond_to?(:for)
      raise(ArgumentError, 'Image Handler is invalid') unless image_handler.nil? || ([:size, :resize, :thumbnail].all? { |m| image_handler.respond_to?(m) })

      raise(ArgumentError, 'Missing required :region option') unless @options[:server].key?(:region)
      raise(ArgumentError, 'Missing required :access_key_id option') unless @options[:server].key?(:access_key_id)
      raise(ArgumentError, 'Missing required :secret_access_key option') unless @options[:server].key?(:secret_access_key)
      raise(ArgumentError, 'Missing required :bucket_name option') unless @options[:server].key?(:bucket_name)

      @options[:url] = 'https://' + @options[:server][:bucket] + '.s3.amazonaws.com' unless @options.key?(:url)

      @headers = {}
      @response = {}
    end

    # of initialize

    # Logger is a class property
    class <<self
      def logger
        @logger ||= Logger.new(STDOUT)
      end

      def logger=(val)
        @logger = val
      end
    end

    # Runs request-response cycle.
    # @param [Hash] params Request parameters. :cmd option is required.
    # @option params [String] :cmd Command to be performed.
    # @see VALID_COMMANDS
    def run(params)

      @adapter = ElFinderS3::Adapter.new(@options[:server], @options[:cache_connector])
      @root = ElFinderS3::Pathname.new(adapter, @options[:root]) #Change - Pass the root dir here

      begin
        @params = params.dup
        @headers = {}
        @response = {}
        @response[:errorData] = {}

        if VALID_COMMANDS.include?(@params[:cmd])

          if @options[:thumbs]
            @thumb_directory = @root + @options[:thumbs_directory]
            @thumb_directory.mkdir unless @thumb_directory.exist?
            raise(RuntimeError, "Unable to create thumbs directory") unless @thumb_directory.directory?
          end

          @current = @params[:current] ? from_hash(@params[:current]) : nil
          @target = (@params[:target] and !@params[:target].empty?) ? from_hash(@params[:target]) : nil
          if params[:targets]
            @targets = @params[:targets].map { |t| from_hash(t) }
          end

          begin
            send("_#{@params[:cmd]}")
          rescue Exception => exception
            puts exception.message
            puts exception.backtrace.inspect
            @response[:error] = 'Access Denied'
          end
        else
          invalid_request
        end

        @response.delete(:errorData) if @response[:errorData].empty?

        return @headers, @response
      ensure
        adapter.close
      end
    end

    # of run

    #
    def to_hash(pathname)
      # note that '=' are removed
      Base64.urlsafe_encode64(pathname.path.to_s).chomp.tr("=\n", "")
    end

    # of to_hash

    #
    def from_hash(hash)
      # restore missing '='
      len = hash.length % 4
      hash += '==' if len == 1 or len == 2
      hash += '=' if len == 3

      decoded_hash = Base64.urlsafe_decode64(hash)
      decoded_hash = decoded_hash.respond_to?(:force_encoding) ? decoded_hash.force_encoding('utf-8') : decoded_hash

      @root + decoded_hash
    rescue ArgumentError => e
      if e.message != 'invalid base64'
        raise
      end
      nil
    end

    # of from_hash

    # @!attribute [w] options
    # Options setter.
    # @param value [Hash] Options to be merged with instance ones.
    # @return [Hash] Updated options.
    def options=(value = {})
      value.each_pair do |k, v|
        @options[k.to_sym] = v
      end
      @options
    end

    # of options=

    ################################################################################
    protected

    #
    def _open(target = nil)
      target ||= @target

      if target.nil?
        _open(@root)
        return
      end

      if perms_for(target)[:read] == false
        @response[:error] = 'Access Denied'
        return
      end

      if target.file?
        @response[:file_data] = @target.read
        @response[:mime_type] = mime_handler.for(@target)
        @response[:disposition] = 'attachment'
        @response[:filename] = @target.basename.to_s
      elsif target.directory?
        @response[:cwd] = cwd_for(target)
        @response[:cdc] = target.children.
          reject { |child| perms_for(child)[:hidden] }.
          sort_by { |e| e.basename.to_s.downcase }.map { |e| cdc_for(e) }.compact

        if @params[:tree]
          @response[:tree] = {
            :name => @options[:home],
            :hash => to_hash(@root),
            :dirs => tree_for(@root),
          }.merge(perms_for(@root))
        end

        if @params[:init]
          @response[:disabled] = @options[:disabled_commands]
          @response[:params] = {
            :dotFiles => @options[:allow_dot_files],
            :uplMaxSize => @options[:upload_max_size],
            :archives => @options[:archivers].keys,
            :extract => @options[:extractors].keys,
            :url => @options[:url]
          }
        end

      else
        @response[:error] = "Directory does not exist"
        _open(@root) if File.directory?(@root)
      end

    end

    # of open

    def _ls
      if @target.directory?
        files = @target.files.reject { |child| perms_for(child)[:hidden] }

        @response[:list] = files.map { |e| e.basename.to_s }.compact
      else
        @response[:error] = "Directory does not exist"
      end

    end

    # of open

    def _tree
      if @target.directory?
        @response[:tree] = tree_for(@target).map { |e| cdc_for(e) }.compact
      else
        @response[:error] = "Directory does not exist"
      end

    end

    # of tree

    #
    def _mkdir
      if perms_for(@target)[:write] == false
        @response[:error] = 'Access Denied'
        return
      end
      unless valid_name?(@params[:name])
        @response[:error] = 'Unable to create folder'
        return
      end

      dir = @target + @params[:name]
      if !dir.exist? && dir.mkdir
        @params[:tree] = true
        @response[:added] = [to_hash(dir)]
        _open(@target)
      else
        @response[:error] = "Unable to create folder"
      end
    end

    # of mkdir

    #
    def _mkfile
      if perms_for(@target)[:write] == false
        @response[:error] = 'Access Denied'
        return
      end
      unless valid_name?(@params[:name])
        @response[:error] = 'Unable to create file'
        return
      end

      file = @target + @params[:name]
      file.type = :file
      if !file.exist? && file.touch
        @response[:select] = [to_hash(file)]
        _open(@target)
      else
        @response[:error] = "Unable to create file"
      end
    end

    # of mkfile

    #
    def _rename
      unless valid_name?(@params[:name])
        @response[:error] = "Unable to rename #{@target.ftype}"
        return
      end

      to = @target.fullpath.dirname + @params[:name]

      perms_for_target = perms_for(@target)
      if perms_for_target[:locked] == true
        @response[:error] = 'Access Denied'
        return
      end

      perms_for_current = perms_for(@target)
      if perms_for_current[:write] == false
        @response[:error] = 'Access Denied'
        return
      end

      if to.exist?
        @response[:error] = "Unable to rename #{@target.ftype}. '#{to.basename}' already exists"
      else
        to = @target.fullpath.rename(to)
        if to
          @response[:added] = [cdc_for(to)]
          @response[:removed] = [to_hash(@target)]
          _open(@current)
        else
          @response[:error] = "Unable to rename #{@target.ftype}"
        end
      end
    end

    # of rename

    #
    def _upload
      if perms_for(@current)[:write] == false
        @response[:error] = 'Access Denied'
        return
      end
      select = []
      @params[:upload].to_a.each do |io|
        name = @options[:original_filename_method].call(io)
        unless valid_name?(name)
          @response[:error] = 'Unable to create file'
          return
        end
        dst = @current + name

        dst.write(io)

        select << to_hash(dst)
      end
      @response[:select] = select unless select.empty?
      _open(@current)
    end

    # of upload

    #
    def _ping
      @headers['Connection'] = 'Close'
    end

    # of ping

    #
    def _paste
      if perms_for(from_hash(@params[:dst]))[:write] == false
        @response[:error] = 'Access Denied'
        return
      end

      added_list = []
      removed_list = []
      @targets.to_a.each do |src|
        if perms_for(src)[:read] == false || (@params[:cut].to_i > 0 && perms_for(src)[:locked] == true)
          @response[:error] ||= 'Some files were not moved.'
          @response[:errorData][src.basename.to_s] = "Access Denied"
          return
        else
          dst = from_hash(@params[:dst]) + src.basename
          if dst.exist?
            @response[:error] ||= 'The target file already exists'
            @response[:errorData][src.basename.to_s] = "already exists in '#{dst.dirname}'"
          else
            if @params[:cut].to_i > 0
              adapter.move(src, dst)

              added_list.push cdc_for(dst)
              removed_list.push to_hash(src)
            else
              command_not_implemented
              return
            end
          end
        end
      end

      @response[:added] = added_list unless added_list.empty?
      @response[:removed] = removed_list unless removed_list.empty?
    end

    # of paste

    #
    def _rm
      if @targets.empty?
        @response[:error] = "No files were selected for removal"
      else
        removed_list = []
        @targets.to_a.each do |target|
          removed_list.concat remove_target(target)
        end
        @response[:removed] = removed_list unless removed_list.empty?
        _open(@current)
      end
    end

    # of rm

    #
    def _duplicate
      command_not_implemented
    end

    # of duplicate

    #
    def _get
      if perms_for(@target)[:read] == true
        @response[:content] = @target.read
      else
        @response[:error] = 'Access Denied'
      end
    end

    # of get

    #
    def _file
      if perms_for(@target)[:read] == true
        @response[:file_data] = @target.read
        @response[:mime_type] = mime_handler.for(@target)
        @response[:disposition] = 'attachment'
        @response[:filename] = @target.basename.to_s
      else
        @response[:error] = 'Access Denied'
      end
    end

    # of file

    #
    def _put
      perms = perms_for(@target)
      if perms[:read] == true && perms[:write] == true
        @target.write @params[:content]
        @response[:changed] = [cdc_for(@target)]
      else
        @response[:error] = 'Access Denied'
      end
    end

    # of put

    #
    def _extract
      command_not_implemented
    end

    # of extract

    #
    def _archive
      command_not_implemented
    end

    # of archive

    #
    def _tmb
      if image_handler.nil?
        command_not_implemented
      else
        @response[:current] = to_hash(@current)
        @response[:images] = {}
        idx = 0
        @current.children.select { |e| mime_handler.for(e) =~ /image/ }.each do |img|
          if (idx >= @options[:thumbs_at_once])
            @response[:tmb] = true
            break
          end
          thumbnail = thumbnail_for(img)
          unless thumbnail.exist? && thumbnail.file?
            imgSourcePath = @options[:url] + '/' + img.path.to_s
            image_handler.thumbnail(imgSourcePath, thumbnail, :width => @options[:thumbs_size].to_i, :height => @options[:thumbs_size].to_i)
            @response[:images][to_hash(img)] = @options[:url] + '/' + thumbnail.path.to_s
            idx += 1
          end
        end
      end
    end

    # of tmb

    #
    def _resize
      command_not_implemented
    end

    # of resize

    ################################################################################
    private

    #
    def upload_max_size_in_bytes
      bytes = @options[:upload_max_size]
      if bytes.is_a?(String) && bytes.strip =~ /(\d+)([KMG]?)/
        bytes = $1.to_i
        unit = $2
        case unit
          when 'K'
            bytes *= 1024
          when 'M'
            bytes *= 1024 * 1024
          when 'G'
            bytes *= 1024 * 1024 * 1024
        end
      end
      bytes.to_i
    end

    #
    def thumbnail_for(pathname)
      result = @thumb_directory + "#{to_hash(pathname)}.png"
      result.type = :file
      result
    end

    #
    def remove_target(target)
      removed = []
      if target.directory?
        target.children.each do |child|
          removed.concat remove_target(child)
        end
      end
      if perms_for(target)[:locked] == true
        @response[:error] ||= 'Some files/directories were unable to be removed'
        @response[:errorData][target.basename.to_s] = "Access Denied"
      else
        begin
          removed.push to_hash(target)
          target.unlink
          if @options[:thumbs] && (thumbnail = thumbnail_for(target)).file?
            removed.push to_hash(thumbnail)
            thumbnail.unlink
          end
        rescue Exception => ex
          @response[:error] ||= 'Some files/directories were unable to be removed'
          @response[:errorData][target.basename.to_s] = "Remove failed"
        end
      end

      removed
    end

    def mime_handler
      @options[:mime_handler]
    end

    #
    def image_handler
      @options[:image_handler]
    end

    def cwd_for(pathname)
      {
        :name => pathname.basename.to_s,
        :hash => to_hash(pathname),
        :mime => 'directory',
        :rel => pathname.is_root? ? @options[:home] : (@options[:home] + '/' + pathname.path.to_s),
        :size => 0,
        :date => pathname.mtime.to_s,
      }.merge(perms_for(pathname))
    end

    def cdc_for(pathname)
      return nil if @options[:thumbs] && pathname.to_s == @thumb_directory.to_s
      response = {
        :name => pathname.basename.to_s,
        :hash => to_hash(pathname),
        :date => pathname.mtime.to_s
      }
      response.merge! perms_for(pathname)

      if pathname.directory?
        response.merge!(
          :size => 0,
          :mime => 'directory'
        )
      elsif pathname.file?
        response.merge!(
          :size => pathname.size,
          :mime => mime_handler.for(pathname),
          :url => (@options[:url] + '/' + pathname.path.to_s)
        )

        if pathname.readable? && response[:mime] =~ /image/ && !image_handler.nil?
          response.merge!(
            :resize => true,
            :dim => image_handler.size(pathname)
          )
          if @options[:thumbs]
            if (thumbnail = thumbnail_for(pathname)).exist?
              response.merge!(:tmb => (@options[:url] + '/' + thumbnail.path.to_s))
            else
              @response[:tmb] = true
            end
          end
        end

      end

      if pathname.symlink?
        response.merge!(
          :link => to_hash(@root + pathname.readlink), # hash of file to which point link
          :linkTo => (@root + pathname.readlink).relative_to(pathname.dirname.path).to_s, # relative path to
          :parent => to_hash((@root + pathname.readlink).dirname) # hash of directory in which is linked file
        )
      end

      return response
    end

    #
    def tree_for(root)
      root.child_directories(@options[:tree_sub_folders]).
        reject { |child|
        (@options[:thumbs] && child.to_s == @thumb_directory.to_s) || perms_for(child)[:hidden]
      }.
        sort_by { |e| e.basename.to_s.downcase }.
        map { |child|
        {:name => child.basename.to_s,
         :hash => to_hash(child),
         :dirs => tree_for(child),
        }.merge(perms_for(child))
      }
    end

    # of tree_for

    #
    def perms_for(pathname, options = {})
      # skip = [options[:skip]].flatten
      response = {}

      response[:read] = pathname.readable?
      response[:read] &&= specific_perm_for(pathname, :read)
      response[:read] &&= @options[:default_perms][:read]

      response[:write] = pathname.writable?
      response[:write] &&= specific_perm_for(pathname, :write)
      response[:write] &&= @options[:default_perms][:write]

      response[:locked] = pathname.is_root?
      response[:locked] &&= specific_perm_for(pathname, :locked)
      response[:locked] &&= @options[:default_perms][:locked]

      response[:hidden] = false
      response[:hidden] ||= specific_perm_for(pathname, :hidden)
      response[:hidden] ||= @options[:default_perms][:hidden]

      response
    end

    # of perms_for

    #
    def specific_perm_for(pathname, perm)
      pathname = pathname.path if pathname.is_a?(ElFinderS3::Pathname)
      matches = @options[:perms].select { |k, v| pathname.to_s.send((k.is_a?(String) ? :== : :match), k) }
      if perm == :hidden
        matches.one? { |e| e.last[perm] }
      else
        matches.none? { |e| e.last[perm] == false }
      end
    end

    # of specific_perm_for

    #
    def valid_name?(name)
      @options[:name_validator].call(name)
    end

    #
    def invalid_request
      @response[:error] = "Invalid command '#{@params[:cmd]}'"
    end

    # of invalid_request

    #
    def command_not_implemented
      @response[:error] = "Command '#{@params[:cmd]}' not implemented"
    end # of command_not_implemented

  end # of class Connector
end # of module ElFinderS3
