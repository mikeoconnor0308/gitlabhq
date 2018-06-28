module QA
  module Page
    module FilePO
      class New < Page::Base
        view 'app/views/projects/blob/_editor.html.haml' do
          element :file_name, "text_field_tag 'file_name'"
          element :editor, '#editor'
        end

        view 'app/views/shared/_commit_message_container.html.haml' do
          element :commit_message, "text_area_tag 'commit_message'"
        end

        view 'app/views/projects/_commit_button.html.haml' do
          element :commit_changes, "button_tag 'Commit changes'"
        end

        def add_name(name)
          fill_in 'file_name', with: name
        end

        def add_content(content)
          find('#editor>textarea', visible: false).set content
        end

        def add_commit_message(message)
          fill_in 'commit_message', with: message
        end

        def commit_changes
          click_on 'Commit changes'
        end
      end
    end
  end
end