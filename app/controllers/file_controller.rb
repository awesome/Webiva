# Copyright (C) 2009 Pascal Rettig.

require 'mime/types' 

class FileController < CmsController

  permit "editor_files"

  layout "manage"
  
  before_filter :calculate_image_size

  protected  

  def calculate_image_size
    @icon_size = (params[:icon_size]||64).to_i
    
    @image_sizes = DomainFile.image_sizes
    @image_sizes.each do |sz|
      @image_size = sz[0]
      break if sz[1] >= @icon_size
    end
    
    @thumb_size = params[:thumb_size] || 'icon'
    @field = params[:field] || ''
    @select = params[:select] || 'img'
    
    @popup = params[:popup]

    @mce = params[:mce]
    
    @order = params[:order] || 'name'
   @order_options = [ ['Name >','name'],
                       ['Name <','name_desc'],
                       ['Created Date >','created_at' ],
                       ['Created Date <','created_at_desc'],
                       ['Size >','file_size' ],
                       ['Size <','file_size_desc'],
                       ['Extension >','extension' ],
                       ['Extension <','extension_desc'],
                     ]
  end

  public

  def index
  
    cms_page_info "Files &amp; Images", "files_and_images"
    
    folder_id = params[:path][0] if params[:path]
    
    @root_folder = DomainFile.root_folder
    
    if folder_id && folder_id.to_i > 0
      @folder = DomainFile.find(folder_id)
      if @folder.file_type != 'fld'
        @folder  = @folder.parent
      end  
    end
    
    @folder= @root_folder unless @folder
    
    @selectedFolder = @folder.id
    
    @select = 'all'
    @full_page = true
    @onload = 'FileEditor.init();'
    
    require_js('edit_area/edit_area_loader')
	  
   
  end
  
  def load_folder
    calculate_image_size
  
    @callback = params[:callback] || 'SCMS.setFileField'
  
  	folder_id = params[:path][0]
  	@folder = DomainFile.find_folder(folder_id)
  	
  	if(params[:file_id]) 
  	  @file = DomainFile.find_by_id(params[:file_id])
  	elsif @folder.id != 1
  	  @file = @folder
  	end 
  	
  	session[:cms_last_folder_id] = @folder.id if @folder
  	
    @file_manager_update = true
  	
  	render :action => 'load_folder'
  end

  def update_icon_sizes
    @folder = DomainFile.find_folder(params[:folder_id])
    @load_request = params[:load_request]
    @icon_size = params[:icon_size]
    raise 'Invalid Folder' unless @folder
    
    
    render :action => 'update_icon_sizes'
  end

  def popup
    calculate_image_size
    
    folder_id = params[:path][0] || params[:file_id] || nil
    
    @callback = params[:callback] || 'SCMS.setFileField'
    @mce = params[:mce]
    @popup = true
    
    @root_folder = DomainFile.root_folder
    
    if folder_id && folder_id.to_i > 0
      @folder = DomainFile.find_by_id(folder_id)
      
      if @folder && @folder.file_type != 'fld'
        @folder  = @folder.parent 
      end
    
    end
    if !@folder && session[:cms_last_folder_id]
      @folder = DomainFile.find_by_id_and_file_type(session[:cms_last_folder_id],'fld')
    end
    
    @folder= @root_folder unless @folder
    
    @selectedFolder = @folder.id
    
    raise 'Bad Folder' unless @folder
    
    session[:cms_last_folder_id] = @folder.id if @folder
    
    @onload = 'FileEditor.init();'
    render :action => 'index', :layout => @mce ? 'manage_mce' : 'manage_window'
  end
  
  def load_details
    @df = DomainFile.find_by_id(params[:file_id])
  end
  
  
  def file_manager_update
  
  
    calculate_image_size
    
    if session[:upload_file_worker]
      file_processor =  MiddleMan.worker(session[:upload_file_worker])
      if file_processor
        if file_processor.finished?
          @files = []
          @files = DomainFile.find(:all,:conditions => { :id => file_processor.uploaded_ids })
          file_processor.delete
          session[:upload_file_worker] = nil
          calculate_image_size
          @hide_item = true
          @file_manager_update = true
          render :partial => 'file_manager_update'
        else
          render :partial => 'file_manager_processing'
        end
      else
        render :nothing => true
      end
    else
    	render :nothing => true
    end
  end
  
  upload_status_for :upload 
  
  
  def upload
  
    dir,file_name = DomainFile.save_uploaded_file(params[:upload_file][:filename])
    
    
    worker_key = MiddleMan.new_worker(:class => :file_worker,
                                      :args => { :filename => file_name,
                                                 :domain_id => DomainModel.active_domain_id,
                                                 :parent_id => params[:upload_file][:parent_id],
                                                 :creator_id => myself.id,
                                                 :tmp_dir => dir,
                                                 :extract_archive => params[:extract_archive],
                                                 :replace_same => params[:replace_same]
                                                })
    #worker = MiddleMan.worker(worker_key)
    session[:upload_file_worker] = worker_key

    render :nothing => true
  end
  
  def rename_file
    atr = params[:file] 
    
    calculate_image_size
    
    @df = DomainFile.find(params[:file_id])
    
    if @df.name != atr[:name]
      @invalid_filename = true unless @df.rename(atr[:name])
    end
      
    render :action => 'rename_file'
  end
  
  def move_files
    
    file_ids = params[:file_id]
    folder_id = params[:folder_id]
    
    files = DomainFile.find(file_ids)
    
    files.each do |file|
      if file.parent.special == 'gallery' && file.parent.gallery
        img = file.parent.gallery.gallery_images.find_by_domain_file_id(file.id)
        img.domain_file_id = nil
        img.destroy if img
      end
      
      folder = DomainFile.find(:first,:conditions => ['file_type = "fld" AND id=?',folder_id])
      
      if active_module?('media') && folder.gallery
        gi = folder.gallery.gallery_images.create(:domain_file_id => file.id)
      end
      
      folder.children << file  
    end
      
    render :nothing => true
  end
  
  def replace_file
    @file = DomainFile.find_by_id(params[:file_id])
    
    @replace = DomainFile.find_by_id(params[:replace_id])
    
    if @file && @replace
      @replaced = @file.replace(@replace)
    end
  end
  
  def delete_revision
    @revision = DomainFileVersion.find_by_id(params[:revision_id])
    
    @file = @revision.domain_file
    
    @revision.destroy
    
    @selected_tab = 'Revisions'
  end
  
  def extract_revision
    @revision = DomainFileVersion.find_by_id(params[:revision_id])
    @file = @revision.extract
  end
  
  def copy_file
    @file = DomainFile.find_by_id(params[:file_id])
    @file = @file.copy_file
  end

  def create_folder
     calculate_image_size
  
     folder_id = params[:folder_id]
     
     parent_folder = DomainFile.find(folder_id)
     
     if parent_folder
     
      name = 'New Folder'.t
      @hide_item = true
      
      gallery_folder = Configuration.options[:gallery_folder].to_i == parent_folder.id
      
      @folder = parent_folder.children.create(:name => name,:file_type => 'fld',:special => gallery_folder ? 'gallery' : '')
      @parent_id = parent_folder.id
      if gallery_folder
        @folder.create_gallery(:name => name, :occurred_at => Time.now)
      end
      render :partial => 'create_folder'
     else
      render :nothing => true
     end
  end
  
  def update_title
    calculate_image_size
     
    file_id = params[:file_id]
    title = params[:title]
    
    file = DomainFile.find(file_id)
    
    if file
      file.update_attributes(:name => title)
      
      if file.special == 'gallery' && file.gallery
        if(!file.gallery.update_attributes(:name => title))
          raise file.gallery.inspect
        end
      end
    end
    
    @parent_id = file.parent_id
    @select = params[:select] || 'img'
  
    render :partial => 'update_file', :locals => { :file => file}
  end
  
  def delete_file
    file_id = params[:file_id]
    
    file = DomainFile.find(file_id)
    file.destroy
    render :nothing => true
  end
  
  def delete_files
    file_id = params[:file_id]
    
    files = DomainFile.find(file_id)
    parent = files[0].parent
    files.each { |fl| fl.destroy }
    
    render :nothing => true
  end
  
  
  def make_private
    file = DomainFile.find(params[:file_id])
    file.update_private!(true)
    
    file.reload

    calculate_image_size 

    render :partial => 'update_file',  :locals => { :file => file }
    
  end
  
  def make_public
  
    file = DomainFile.find(params[:file_id]);
    file.update_private!(false)
    
    file.reload
    
    calculate_image_size 
    render :partial => 'update_file', :locals => { :file => file }
  
  end
  
  def folder_archive
  
    file = DomainFile.find(params[:folder_id])
    DomainModel.run_worker('DomainFile',file.id,:download_directory)
  end
  
  def switch_processor
    file = DomainFile.find(params[:file_id])
    
    #file.update_processor(:processor => params[:file_processor] )
    DomainModel.run_worker('DomainFile',file.id,:update_processor,{ :processor => params[:file_processor] })
    file.processor_status = 'processing'
    
    @select = params[:select] || 'img'

    calculate_image_size 
    render :partial => 'update_file', :locals => { :file => file }
  end
  
  def priv
    file_id = params[:path][0]
    size = params[:path][1]
    
    domain_file = DomainFile.find(:first,:conditions => [ 'id=?',file_id ])
    filename = domain_file.filename(size)
    mime_types =  MIME::Types.type_for(filename) 
    
    send_file(filename,
              :type => mime_types[0] ? mime_types[0].to_s : 'text/plain',
              :disposition => 'inline',
              :filename => domain_file.name)
  end
  
  def search
    srch = params[:search][:search]
    order = params[:search][:order]
    
    @results = DomainFile.run_search(srch,order)
    
    render :partial => 'search_results'
  
  end
  
  def edit_file
    @file = DomainFile.find(params[:file_id])
    
    @file = nil unless @file.editable?
    
    if(@file && params[:contents])
      @file.contents = params[:contents]
      @file.save
      render :partial => 'edited_file'
    else
      render :partial => 'edit_file'
    end
  end
end