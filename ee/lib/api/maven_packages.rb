# frozen_string_literal: true
module API
  class MavenPackages < Grape::API
    MAVEN_ENDPOINT_REQUIREMENTS = {
      file_name: API::NO_SLASH_URL_PART_REGEX
    }.freeze

    MAVEN_METADATA_FILE = 'maven-metadata.xml'.freeze

    content_type :md5, 'text/plain'
    content_type :sha1, 'text/plain'
    content_type :binary, 'application/octet-stream'

    before do
      require_packages_enabled!
      authenticate_non_get!
      authorize_packages_feature!
    end

    helpers do
      def require_packages_enabled!
        not_found! unless Gitlab.config.packages.enabled
      end

      def authorize_packages_feature!
        forbidden! unless user_project.feature_available?(:packages)
      end

      def authorize_download_package!
        authorize!(:read_package, user_project)
      end

      def authorize_create_package!
        authorize!(:admin_package, user_project)
      end

      def extract_format(file_name)
        name, _, format = file_name.rpartition('.')

        if %w(md5 sha1).include?(format)
          [name, format]
        else
          [file_name, nil]
        end
      end

      def verify_package_file(package_file, uploaded_file)
        stored_sha1 = Digest::SHA256.hexdigest(package_file.file_sha1)
        expected_sha1 = uploaded_file.sha256

        if stored_sha1 == expected_sha1
          no_content!
        else
          conflict!
        end
      end
    end

    params do
      requires :id, type: String, desc: 'The ID of a project'
    end
    resource :projects, requirements: API::PROJECT_ENDPOINT_REQUIREMENTS do
      desc 'Download the maven package file' do
        detail 'This feature was introduced in GitLab 11.3'
      end
      params do
        requires :path, type: String, desc: 'Package path'
        requires :file_name, type: String, desc: 'Package file name'
      end
      get ':id/packages/maven/*path/:file_name', requirements: MAVEN_ENDPOINT_REQUIREMENTS do
        authorize_download_package!

        file_name, format = extract_format(params[:file_name])

        package = ::Packages::MavenPackageFinder
          .new(user_project, params[:path]).execute!

        package_file = ::Packages::PackageFileFinder
          .new(package, file_name).execute!

        case format
        when 'md5'
          package_file.file_md5
        when 'sha1'
          package_file.file_sha1
        when nil
          present_carrierwave_file!(package_file.file)
        end
      end

      desc 'Upload the maven package file' do
        detail 'This feature was introduced in GitLab 11.3'
      end
      params do
        requires :path, type: String, desc: 'Package path'
        requires :file_name, type: String, desc: 'Package file name'
      end
      put ':id/packages/maven/*path/:file_name/authorize', requirements: MAVEN_ENDPOINT_REQUIREMENTS do
        authorize_create_package!

        require_gitlab_workhorse!
        Gitlab::Workhorse.verify_api_request!(headers)

        status 200
        content_type Gitlab::Workhorse::INTERNAL_API_CONTENT_TYPE
        ::Packages::PackageFileUploader.workhorse_authorize(has_length: true)
      end

      desc 'Upload the maven package file' do
        detail 'This feature was introduced in GitLab 11.3'
      end
      params do
        requires :path, type: String, desc: 'Package path'
        requires :file_name, type: String, desc: 'Package file name'
        optional 'file.path', type: String, desc: %q(path to locally stored body (generated by Workhorse))
        optional 'file.name', type: String, desc: %q(real filename as send in Content-Disposition (generated by Workhorse))
        optional 'file.type', type: String, desc: %q(real content type as send in Content-Type (generated by Workhorse))
        optional 'file.size', type: Integer, desc: %q(real size of file (generated by Workhorse))
        optional 'file.md5', type: String, desc: %q(md5 checksum of the file (generated by Workhorse))
        optional 'file.sha1', type: String, desc: %q(sha1 checksum of the file (generated by Workhorse))
        optional 'file.sha256', type: String, desc: %q(sha256 checksum of the file (generated by Workhorse))
      end
      put ':id/packages/maven/*path/:file_name', requirements: MAVEN_ENDPOINT_REQUIREMENTS do
        authorize_create_package!

        require_gitlab_workhorse!

        file_name, format = extract_format(params[:file_name])

        uploaded_file = UploadedFile.from_params(params, :file, ::Packages::PackageFileUploader.workhorse_local_upload_path)
        bad_request!('Missing package file!') unless uploaded_file

        package = ::Packages::MavenPackageFinder
          .new(user_project, params[:path]).execute

        unless package
          if file_name == MAVEN_METADATA_FILE
            # Maven uploads several files during `mvn deploy` in next order:
            #   - my-company/my-app/1.0-SNAPSHOT/my-app.jar
            #   - my-company/my-app/1.0-SNAPSHOT/my-app.pom
            #   - my-company/my-app/1.0-SNAPSHOT/maven-metadata.xml
            #   - my-company/my-app/maven-metadata.xml
            #
            # The last xml file does not have VERSION in URL because it contains
            # information about all versions.
            package_name, version = params[:path], nil
          else
            package_name, _, version = params[:path].rpartition('/')
          end

          package_params = {
            name: package_name,
            path: params[:path],
            version: version
          }

          package = ::Packages::CreateMavenPackageService
            .new(user_project, current_user, package_params).execute
        end

        case format
        when 'sha1'
          # After uploading a file, Maven tries to upload a sha1 and md5 version of it.
          # Since we store md5/sha1 in database we simply need to validate our hash
          # against one uploaded by Maven. We do this for `sha1` format.
          package_file = ::Packages::PackageFileFinder
            .new(package, file_name).execute!

          verify_package_file(package_file, uploaded_file)
        when nil
          file_params = {
            file:      uploaded_file,
            size:      params['file.size'],
            file_name: file_name,
            file_type: params['file.type'],
            file_sha1: params['file.sha1'],
            file_md5:  params['file.md5']
          }

          ::Packages::CreatePackageFileService.new(package, file_params).execute
        end
      end
    end
  end
end
