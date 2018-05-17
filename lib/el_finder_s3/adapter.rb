module ElFinderS3
  require 'cache'

  class Adapter
    attr_reader :server, :s3_connector

    def initialize(server, cache_connector)
      @server = {
        response_cache_expiry_seconds: 3000
      }
      @cached_responses = {}
      @s3_connector = ElFinderS3::S3Connector.new server
      @cache_connector = cache_connector || ElFinderS3::CacheConnector.new
    end

    def close
      true
    end

    def children(pathname, with_directory)
      elements = @cache_connector.cached ElFinderS3::Operations::CHILDREN, pathname do
        @s3_connector.ls_la(pathname)
      end

      result = []
      elements[:folders].each { |folder|
        result.push(pathname.fullpath + ElFinderS3::S3Pathname.new(@s3_connector, folder, {:type => :directory}))
      }
      elements[:files].each { |file|
        if with_directory
          result.push(pathname.fullpath + ElFinderS3::S3Pathname.new(@s3_connector, file, {:type => :file}))
        else
          result.push(ElFinderS3::S3Pathname.new(@s3_connector, file, {:type => :file}))
        end
      }
      result
    end

    def touch(pathname, options={})
      if @s3_connector.touch(pathname.to_file_prefix_s)
        @cache_connector.clear_cache(pathname, false)
        true
      end
    end

    def exist?(pathname)
      @cache_connector.cached ElFinderS3::Operations::EXIST, pathname do
        @s3_connector.exist? pathname
      end
    end

    def path_type(pathname)
      @cache_connector.cached ElFinderS3::Operations::PATH_TYPE, pathname do
        # FIXME. Не самое лучшее решение
        File.extname(pathname.to_s).empty? ? :directory : :file
      end
    end

    def size(pathname)
      @cache_connector.cached :size, pathname do
        @s3_connector.size(pathname)
      end
    end

    def mtime(pathname)
      @cache_connector.cached ElFinderS3::Operations::MTIME, pathname do
        @s3_connector.mtime(pathname)
      end
    end

    def rename(pathname, new_pathname)
      rename_result = pathname.file? ? rename_file(pathname, new_pathname) : rename_directory(pathname, new_pathname)

      if rename_result
        @cache_connector.clear_cache(pathname)
        new_pathname
      else
        false
      end
    end

    # FIXME
    def rename_directory(pathname, new_pathname)
      false
    end

    def rename_file(pathname, new_pathname)
      @s3_connector.rename(pathname.to_file_prefix_s, new_pathname.to_file_prefix_s)
    end

    ##
    # Both rename and move perform an FTP RNFR/RNTO (rename).  Move differs because
    # it first changes to the parent of the source pathname and uses a relative path for
    # the RNFR.  This seems to allow the (Microsoft) FTP server to rename a directory
    # into another directory (e.g. /subdir/target -> /target )
    def move(pathname, new_pathname)
      #FIXME
      # ftp_context(pathname.dirname) do
      #   ElFinderS3::Connector.logger.debug "  \e[1;32mFTP:\e[0m    Moving #{pathname} to #{new_pathname}"
      #   rename(pathname.basename.to_s, new_pathname.to_s)
      # end
      # clear_cache(pathname)
      # clear_cache(new_pathname)
    end

    def mkdir(pathname)
      if @s3_connector.mkdir(pathname.to_prefix_s)
        @cache_connector.clear_cache(pathname)
      else
        false
      end
    end

    def delete(pathname)
      path = pathname.file? ? pathname.to_file_prefix_s : pathname.to_prefix_s
      if @s3_connector.delete(path)
        @cache_connector.clear_cache(pathname)
      else
        false
      end
    end

    def retrieve(pathname)
      @s3_connector.get(pathname.to_file_prefix_s)
    end

    def store(pathname, content)
      @s3_connector.store(pathname.to_file_prefix_s, content)
      #TODO clear_cache(pathname)
    end
  end
end
