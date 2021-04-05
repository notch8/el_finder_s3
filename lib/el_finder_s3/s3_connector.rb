require 'aws-sdk-s3'

module ElFinderS3
  class S3Connector
    :s3_client
    :bucket_name

    def initialize(server)
      Aws.config.update(
        {
          region: server[:region],
          force_path_style: true,
          credentials: Aws::Credentials.new(server[:access_key_id], server[:secret_access_key])
        }
      )
      Aws.config.update({ endpoint: server[:endpoint]}) if server[:endpoint]

      @bucket_name = server[:bucket_name]
      @s3_client = Aws::S3::Client.new
    end

    def ls_la(pathname)
      prefix = pathname.to_prefix_s
      #query = { bucket: @bucket_name, delimiter: '/', encoding_type: 'url', max_keys: 100, prefix: prefix }
      query = { bucket: @bucket_name, delimiter: '/', encoding_type: nil, max_keys: 100, prefix: prefix }

      response = @s3_client.list_objects(query)
      result = {
        :folders => [],
        :files => []
      }

      #Files
      response.contents.each { |e|
        if e.key != prefix
          e.key = e.key.gsub(prefix, '')
          result[:files].push(e[:key])
        end
      }
      #Folders
      response.common_prefixes.each { |f|
        if f.prefix != '' && f.prefix != prefix && f.prefix != '/'
          f.prefix = f.prefix.split('/').last
          result[:folders].push(f[:prefix])
        end
      }
      return result
    end

    # @param [ElFinderS3::Pathname] pathname
    def exist?(pathname)
      query = {
        bucket: @bucket_name,
        key: pathname.file? ? pathname.to_file_prefix_s : pathname.to_prefix_s
      }
      begin
        @s3_client.head_object(query)
        true
      rescue Aws::S3::Errors::NotFound
        false
      end
    end

    def mkdir(folder_name)
      begin
        @s3_client.put_object(bucket: @bucket_name, key: folder_name)
        true
      rescue
        false
      end
    end

    def touch(filename)
      begin
        @s3_client.put_object(bucket: @bucket_name, key: filename)
        true
      rescue
        false
      end
    end

    def store(filename, content)
      if content.is_a?(MiniMagick::Image)
        @s3_client.put_object(bucket: @bucket_name, key: filename, body: content.to_blob, acl: 'public-read')
      elsif @s3_client.put_object(bucket: @bucket_name, key: filename, body: content, acl: 'public-read')
      end
    end

    def get(filename)
      response = @s3_client.get_object(bucket: @bucket_name, key: filename)
      return nil unless !response.nil?
      response.body
    end

    # TODO не определяется размер
    def size(pathname)
      query = {
        bucket: @bucket_name,
        key: pathname.file? ? pathname.to_file_prefix_s : pathname.to_prefix_s
      }
      begin
        head = @s3_client.head_object(query)
        head[:content_length]
      rescue Aws::S3::Errors::NotFound
        0
      end
    end

    def mtime(pathname)
      query = {
        bucket: @bucket_name,
        key: pathname.file? ? pathname.to_file_prefix_s : pathname.to_prefix_s
      }
      begin
        head = @s3_client.head_object(query)
        head[:last_modified]
      rescue Aws::S3::Errors::NotFound
        0
      end
    end

    def delete(path)
      begin
        @s3_client.delete_object(bucket: @bucket_name, key: path)
        true
      rescue
        false
      end
    end

    def rename(path_from, path_to)
      begin
        @s3_client.copy_object(
          bucket: @bucket_name,
          key: path_to,
          copy_source: "#{@bucket_name}/#{path_from}",
          acl: 'public-read'
        )
        @s3_client.delete_object(bucket: @bucket_name, key: path_from)

        true
      rescue
        false
      end
    end
  end
end
