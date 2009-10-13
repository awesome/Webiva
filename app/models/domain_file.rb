# Copyright (C) 2009 Pascal Rettig.

require 'mime/types'
require "image_size"
require "digest/sha1"
require "find"
require 'ftools'
require 'fileutils'
require 'RMagick'
class DomainFile < DomainModel

  @@image_size_array = [ [ :icon, 32], [:thumb, 64], [:preview, 128 ], [ :small , 256 ] ]
  @@image_sizes = {}
  @@image_size_array.each { |size|  @@image_sizes[size[0]] = [ size[1], size[1] ]  }
 
  
  @@archive_extensions = ['zip','gz','tar' ]
  
  @@disable_file_processing = false

  serialize :meta_info
 
  acts_as_tree :order => 'file_type=\'fld\' DESC, name'
  
  has_one :gallery
  has_one :gallery_image
  
  belongs_to :creator, :class_name => 'EndUser',:foreign_key => :creator_id
  
  @@img_file_extensions = %w(gif jpg png jpeg bmp tif)
  @@thm_file_extensions = %w(pdf)
  @@public_file_extensions = %w(swf flv mov js htc ico mp3 css)
  
  cattr_accessor :public_file_extensions
  
	attr_accessor :skip_transform
    
  def self.image_sizes
    @@image_size_array
  end
  
  has_and_belongs_to_many :mail_templates
  
  has_many :instances, :class_name => 'DomainFileInstance', :dependent => :delete_all
  has_many :versions, :class_name => 'DomainFileVersion', :dependent => :destroy, :order => 'domain_file_versions.id DESC'
  
  
   ###########
   # Core File Methods
   ###########
   
   def self.save_uploaded_file(file)
     dir = self.generate_temporary_directory
     filename = File.join(dir,File.basename(DomainFile.sanitize_filename(file.original_filename)))
     File.open(filename, "wb") { |f| f.write(file.read) }
     File.chmod(0664,filename)
     return dir,filename
   end
   
   # Set the file data   
   def filename=(file_data)
    @file_data = file_data
    if @file_data.is_a? File
      # Trick from file_column - make File look like an uploaded file by most accounts
      @file_data.extend DomainFile::FileCompat
    end
   end
   
   # Replace this file with a different file
   def replace(file)
    return false if self.folder?
    self.reload(:lock => true)
    File.open(file.filename,"rb") do |f|
      self.filename = f
      self.name = file.name
      if(self.save)
        file.destroy
        return true
      end
    end
    return false
   end
   
   def copy_file(user_id=nil)
    return false if self.folder?
    
    df = DomainFile.new(:parent_id => self.parent_id, :creator_id => user_id || self.creator_id, :private => self.private)
    File.open(self.filename,"rb") do |f|
      df.filename = f
      if(df.save)
        return df
      end
    end
    return nil
   end
   
   def find_match
     DomainFile.find_by_parent_id_and_name(self.parent_id,self.name,:conditions => ['domain_files.id != ? AND file_type !="fld"',self.id])
   end
   
   def find_folder_match
     DomainFile.find_by_parent_id_and_name(self.parent_id,self.name,:conditions => ['domain_files.id != ? AND file_type ="fld"',self.id])
   end
   
   def replace_same
   
    # folders need to try to find a folder match and move all their nested children to the matched folder
    # then get rid of themselves
    if(self.folder?)
      match = find_folder_match
      if(match)
        self.children(true).each do |child|
          child.update_attribute(:parent_id,match.id)
          child.replace_same
        end
        self.reload
        self.destroy
        return match
      end
    else
      match = find_match
      
      if match
        match.replace(self)
        return match
      end
      return self
    end
    return false
    
   end
   
   # Copy copy this file to a new file
   def rename(new_name)
   
    return false if new_name.blank?

    if self.folder?
      self.update_attributes(:name => new_name)
      return true
    end
   
    new_name = DomainFile.sanitize_filename(new_name)
    if File.extname(new_name)[1..-1] != self.extension
      return false
    end
    
    return false if new_name.blank?
   
    tmp_dir = DomainFile.generate_temporary_directory
    new_filename = File.join(tmp_dir,new_name)
    if FileUtils.copy_file(self.abs_filename,new_filename,true)
      File.open(new_filename,"rb") do |f|
        self.filename = f
        self.name = new_name
        if(self.save)
          FileUtils.rm_rf(tmp_dir)
          return true
        end
      end
    end
    FileUtils.rm_rf(tmp_dir)
    return false
   end
   
   before_update :process_file_update
   after_update :update_image_instances
   validate_on_create :preprocess_file
   after_create :process_file
   
   after_destroy :cleanup_file
   
   def process_file_update
    if @file_data && self.id
      # if we already have a file,
      # save the older version in a subdirectory (with a unguessable hash)
      # check for FileInstances
      
      self.processor_handler.copy_local! if self.processor != 'local'
      
      DomainFileVersion.archive(self) # Remove all the old versions of the file
      
      self.version_count += 1
      self.file_type = nil
      preprocess_file
      process_file(true)
      
      @file_change = true      
    end
    update_file_path
   end
   
   def update_image_instances
    if @file_change
      if self.instances.length > 0
        grouped_targets = self.instances.group_by(&:target_type)
        
        # Resave all the targets
        grouped_targets.each do |target_type,target_list|
          target_type.constantize.find(:all,:conditions => { :id => target_list.map(&:target_id) }).map(&:save)
        end
        DataCache.expire_container('SiteNode')
        DataCache.expire_container('SiteNodeModifier')
        DataCache.expire_content
      end
    end  
   end
   
   
   # This is called before the file is saved for the first time (we don't have an id)
   def preprocess_file

    current_file_name = nil
    if @file_data
      # Write the filename so we know where to save it (and make sure this file validates)
      begin
        current_file_name =File.basename(DomainFile.sanitize_filename(@file_data.original_filename.to_s.downcase))
        self.write_attribute(:filename,current_file_name)
      rescue Exception => e
        self.write_attribute(:filename,nil)
      end
      
      if current_file_name
			  ext = File.extname(current_file_name)[1..-1]
			  self.extension= ext.downcase if ext.length > 0 
		  end    
		end
		
		# If we're not a folder, get a file type
		if !self.file_type
			if @@img_file_extensions.include?(self.extension)
				self.file_type = 'img'
			elsif @@thm_file_extensions.include?(self.extension)
				self.file_type = 'thm'
			else
				self.file_type = 'doc'
			end  
		end
		
		if self.file_type.to_s != 'fld'
		  self.errors.add_to_base('file is missing') if !current_file_name
		end
		
		# Make sure we're somewhere in the file tree
		self.parent_id = DomainFile.root_folder.id if self.file_type.to_s != 'fld' && !self.parent_id #&& !self.name.blank?
   
    if self.name.blank?
      self.name = current_file_name
    end
		
		
		
   end
   
   # This is called after the file is saved for the first time
   # It will save the file and perform any necessary transforms in images
   # updating the meta data as necessary
   def process_file(update=false)
    if @file_data
    
      # Set the prefix
      self.prefix = "#{DomainFile.generate_prefix}/#{self.id}" if  self.prefix.blank?
      info = {}
      
      # Save the file to the correct location
      FileUtils.mkpath(self.abs_storage_directory);
      
      # Copy the file directly if it's not a file object
      if @file_data.respond_to?(:local_path) and @file_data.local_path and File.exists?(@file_data.local_path)
        FileUtils.copy_file(@file_data.local_path, self.abs_filename)
      elsif @file_data.respond_to?(:read)
        File.open(self.abs_filename,'wb') { |f| f.write(@file_data.read) }
      end
      File.chmod(0664,abs_filename)
      
      
      self.file_size = File.size(self.abs_filename);
      self.stored_at = Time.now # File.mtime(self.abs_filename);

      mime = MIME::Types.type_for(self.abs_filename)
      self.mime_type = mime[0] ? mime[0].to_s : 'application/octet-stream'

      # Unless we're skipping the transform on this
      if !@skip_transform
        if(self.file_type=='img')
          info[:image_size] = {}
          
#          begin
            img = Magick::Image.read(self.abs_filename).first
            
            mime = MIME::Types.type_for(self.abs_filename)
            self.mime_type = mime[0] ? mime[0].to_s : 'application/octet-stream'
            
            info[:image_size][:original] = [ img.columns, img.rows ]
            
            DomainFile.image_sizes.each do |size|
              thumbnail = img.resize_to_fit(size[1],size[1])
              info[:image_size][size[0]] = [ thumbnail.columns, thumbnail.rows ]
              FileUtils.mkpath(self.abs_storage_directory + size[0].to_s);
              thumbnail.write(self.abs_filename(size[0]))
            end
#          rescue Exception => e
#            self.file_type = 'doc'
#          end
        
          # Do the transforms
        end
      
        # Do all the standard transforms
      else  
        # Update the meta data
      end
      
      self.meta_info = info
      
      @file_data = nil
      self.save unless update  # Resave to update the file information if we are during the creation process
    end
    
    post_process! unless @@disable_file_processing 
   end
   
   def set_size(size_name,width,height)
    meta_info[:image_size] ||= {}
    meta_info[:image_size][size_name.to_sym] = [ width, height ]
   end
   
  
   # Make sure all the children have an updated file path
   # TODO: only do this if we need to...
   def after_save #:nodoc:
    if self.file_type == 'fld' && self.children.length > 0
      self.children.each do |child|
        child.save
      end
    end
   end
   
   
   # Check if the storage directory exists, if so, delete
   def cleanup_file #:nodoc:
    self.processor_handler.destroy_remote! if self.processor != 'local'
    if !prefix.blank? && (File.directory?(abs_storage_directory))
      FileUtils.rm_rf(abs_storage_directory)
    end
   end
   
   def destroy_thumbs
    # Need to destroy thumbs and get image size for the domain file version
    if self.meta_info[:image_size]
      self.meta_info[:image_size].each do |size,vals|
        FileUtils.rm_rf(abs_storage_directory + "/" + size.to_s)
      end 
      self.processor_handler.destroy_thumbs! if self.processor != 'local'
    end
   end
   
   
   def relative_filename(size=nil,force=nil)
      # unless we have a filename, return false
      atr = self.read_attribute(:filename)
      return nil unless self.prefix && atr
      
      # Only allow valid file sizes
      size = nil unless force || !size || @@image_sizes[size.to_sym] || DomainFileSize.custom_sizes[size.to_sym]
      self.storage_directory + (size ? "#{size}/" : '') +  atr
   end
   
   # Return the absolute storage directory - valid for opening a file  on the server 
   # Return the relative storage directory
   # Thumbnails are stored in subdirectories prefixed with the file size (../small/file.jpg)
   def abs_filename(size=nil,force=false); "#{RAILS_ROOT}/public" + self.relative_filename(size,force); end
   alias_method :filename, :abs_filename
   
   
   def storage_directory; self.storage_base + "/" + self.prefix + "/"; end
   def abs_storage_directory; "#{RAILS_ROOT}/public" + self.storage_base + "/" + self.prefix + "/"; end
   

   # Return the base storage subdirectory (under public)
   def self.storage_subdir; DomainModel.active_domain[:file_store].to_s; end
   
   def storage_base; self.private? ? DomainFile.private_storage_base : DomainFile.public_storage_base; end
   def self.private_storage_base; "/system/private/#{DomainFile.storage_subdir}"; end
   def self.abs_private_storage_base; "#{RAILS_ROOT}/public" + self.private_storage_base; end
   def self.public_storage_base;  "/system/storage/#{DomainFile.storage_subdir}"; end
   
   
   ######
   # No Doc Internal Core Methods
   ######
   
   private
   
  def update_file_path
    pth = ''
    if self.parent && self.parent.file_path
      pth = self.parent.file_path
    end
    
    pth += '/' unless pth[-1..-1] == '/'
    
    pth +=  self.name.to_s
    
    self.file_path = pth
  end   
  
  public
   
   ###########
   # Convenience Methods
   ###########
   def self.root_folder
      DomainFile.find(:first,:conditions => 'parent_id is NULL') || DomainFile.create(:name => '',:file_type => 'fld') 
   end
   
   def image?; self.file_type == 'img'; end
   def thumb?; self.file_type == 'thm'; end
   def document?;  self.file_type == 'doc'; end
   def folder?;  self.file_type == 'fld'; end
   
   
   
   # Returns a list of subfolders - TODO: Use the 2.1 scopers
   def subfolders
   	self.children.find(:all,:conditions => 'file_type = "fld"', :order=> :filename)
   end	
   
   # Returns a list of files - TODO: Use the 2.1 scopers
   def files
   	self.children.find(:all,:conditions => 'file_type != "fld"', :order=> :filename)
   end
   
   # Find a specific folder
   def self.find_folder(folder_id)
   	self.find(folder_id,:conditions => 'file_type = "fld"')
   end	
   
   # Create a new folder
   def self.create_folder(name,parent_id=nil,options = {})
    unless parent_id
      root = DomainFile.root_folder
      parent_id = root.id
    end
    DomainFile.create(:name => name, 
                      :file_type => 'fld',
                      :parent_id => parent_id,
                      :automatic => options[:automatic] ? true : false ,
                      :special => options[:special] ? options[:special] : '')
   end
   
   # List of folders parent > current
   def ancestors
    lst = [] 
    itm = self
    while itm = itm.parent
        lst << itm
    end
    lst.reverse
   end

   def image_size_options
    opts = [ [ sprintf("Original Image (%dx%d)".t,self.width(:original),self.height(:original)),'' ]  ]
    @@image_size_array.each do |sz|
      opts << [ sprintf("%s (%dx%d)".t,sz[0].to_s.humanize, self.width(sz[0].to_sym),self.height(sz[0].to_sym)), self.editor_url(sz[0])  ]
    end
    
    DomainFileSize.custom_sizes.each do |sym,size_opts|
      opts << [ sprintf("%s (%s)",size_opts[0],size_opts[1]), self.editor_url(sym) ]
    end
    
    opts
   end
   
   # Upload an image 
   def self.image_upload(file,parent_id=nil,user_id=nil)
    unless parent_id
      root = DomainFile.root_folder
      parent_id = root.id
    end
    df = DomainFile.new(:filename => file, :parent_id => parent_id,:creator_id => user_id )
    df.save
    
    if df.file_type == 'img'
      return df
    else
      df.destroy
      return nil
    end
   end
   
   def mini_icon
    "/images/icons/filemanager/mini_folder#{!self.special.blank? ? "_#{self.special}" : ''}.gif"
   end
   
   def folder_icon
    "/images/icons/filemanager/folder#{!self.special.blank? ? "_#{self.special}" : ''}.gif"
   end
  

  # Return an image tag for a file
  def image_tag(size=nil,options = {})
     size_arr = image_size(size)
     url_val = url(size) + "?" + self.stored_at.to_i.to_s
     
     style = options[:style] ? " style='#{options[:style]}'" : ''
     align = options[:align] ? " align='#{options[:align]}'" : ''

     "<img src='#{url_val}' width='#{size_arr[0]}' height='#{size_arr[1]}'#{align}#{style} />"

  end
   
  # Return a url for a file at a specific size
  def url(size=nil)
    return self.processor_handler.url(size) unless self.processor == 'local'
    if self.private?
      return "/website/file/priv/#{self.id.to_s}/#{size.to_s}"
    end
    self.relative_filename(size)
  end
  
  # Return an editor url (that will get processed by the file_instance_extension)
  def editor_url(size=nil)
    return nil if self.private?
    "/__fs__/#{self.prefix}" + (size ? ":#{size}" : '') 
  end
    
  def full_url(size=nil)
    return self.processor_handler.full_url(size) unless self.processor == 'local'
    "http://#{Configuration.domain}#{self.url(size)}"
  end
    
  # Return the size of the actual image
  def image_size(size=nil) 
    return nil unless self.file_type == 'img' || self.file_type == 'thm'
    size=size.to_sym if size
    size = nil unless size && (@@image_sizes[size] || DomainFileSize.custom_sizes[size])
    size ||= :original
    
    return [1,1] unless self.meta_info && self.meta_info[:image_size]
    self.meta_info[:image_size][size] || [1,1]
  end
  
  def thumb_size_names
    sizes = []
    (self.meta_info[:image_size]||{}).each do |size,val|
      sizes << size
    end    
  end
  
  # Return an image's width
  def width(size=nil)
    (image_size(size)||[])[0]
  end
  
  # Return an image's height
  def height(size=nil)
    (image_size(size)||[])[1]
  end
    
  # Return the file's extension
	def extension
	  ext = self.read_attribute(:extension)
	  return ext if ext;
		return unless self.meta_info.is_a?(Hash)
		return self.meta_info[:file_extension] if self.file_type != 'fld'
		return nil
	end
	
	# Is this file an archive file
	def is_archive?
		return @@archive_extensions.include?(self.extension)
	end    
  
 # Return the thumb adjusted size
  # that fits in a box of dimension X dimension
  def thumb_size(size,dimension)
    sz = image_size(size)
    scale_x = dimension.to_f / (sz[0] || 1)
    scale_y = dimension.to_f / (sz[1] || 1)
    scale_factor = scale_x < scale_y ? scale_x : scale_y
    # Return a array of the scaled dimensions
    [ (sz[0] * scale_factor).ceil.to_i, (sz[1] * scale_factor).ceil.to_i ]
  end

  ########
  # File Manager methods
  #########

  def details_partial
    # TODO check for a handler first - folder can have special as well
    case self.file_type
    when 'img': '/file/details/file_image'
    when 'thm': '/file/details/file_thumb'
    when 'doc': '/file/details/file_document'
    when 'fld': '/file/details/file_folder'
    end
  end

  
  def thumbnail_url(theme,size)
    case self.file_type
    when 'img','thm' : url(size)
    when 'doc' : thumbnail_document_icon(theme,size)
    when 'fld' : thumbnail_folder_icon(theme,size)
    end
  end
  
  
  def file_type_match(type)
    if type == 'all' 
      return true if !self.folder?
    elsif type == 'doc'
      return true if self.document? || self.thumb?
    else
      return true if self.file_type == type
    end
    return false
  end
  
  def ordered_children(order)
    self.children.find(:all,:order => DomainFile.order_sql(order))
  end
  
  def self.run_search(src,order = 'name')
    order_details = DomainFile.order_sql(order)
    DomainFile.find(:all,:conditions => ['name LIKE ?',"%#{src}%"],:order => order_details)
  end
  
  def editable?
    self.mime_type.to_s.include?('text') || self.mime_type == 'application/javascript'
  end
  
  def contents
    File.open(self.filename,'r') do |f|
      return f.read
    end
  end
  
  def contents=(val)
    dir = DomainFile.generate_temporary_directory
    
     
    File.open(File.join(dir,self.read_attribute(:filename)),'wb') do |f|
      f.write(val)
    end
    
    File.open(File.join(dir,self.read_attribute(:filename)),'rb') do |f|
      self.filename=f
      self.save
    end
    
    FileUtils.rm_rf(dir)
    
  end
  
  protected 
  
  def self.order_sql(order)
   if(order =~ /^([a-z_]+)(\_desc)$/) 
      desc = ' DESC'
      order = $1
    else
      desc = ''
    end
    
    case order
    when 'file_size'
      'file_type = "fld" DESC, file_size' + desc + ", name"
    when 'created_at'
      'file_type = "fld" DESC, created_at' + desc + ", name"
    when 'extension'
      'file_type = "fld" DESC, extension' + desc + ", name"
    else
      'file_type = "fld" DESC, name' + desc
    end
  end
  
  public

  # return a thumb adjusted size for all file types
  # that fits in a box of dimension X dimension
  # Assume all document/folder/etc thumbnails are square  
  def thumbnail_thumb_size(size,dimension)
    case self.file_type
    when 'img','thm' : thumb_size(size,dimension)
    else [ dimension, dimension ]
    end
  end
  
  protected
  
  def thumbnail_document_icon(theme,size)
    theme_src(theme,"icons/filemanager/document.gif") # TODO - replace with handler to manage different document types
  end
  
  def thumbnail_folder_icon(theme,size)
    theme_src(theme,self.folder_icon)
  end
  
  def theme_src(theme,img=nil) 
    if img.to_s[0..6] == "/images"
     "/themes/#{theme}" + img.to_s
    else
     "/themes/#{theme}/images/" + img.to_s
    end
  end  
  
  public
  
 
   #########
   #  Non Local file processing functions
   #########
 
    def post_process!(background=true)
      return if self.file_type == 'fld'
      opts = Configuration.file_types
      ext = self.extension
      current_processor = opts.default
      opts.options_arr.each do |processor,file_types|
        current_processor = processor if file_types.include?(ext)
      end
      if current_processor != 'local'
        if background
          DomainModel.run_worker('DomainFile',self.id,:update_processor,{ :processor => current_processor, :new_file => true })  
        else
          self.update_processor(:processor => current_processor, :new_file => true)
        end
      end
    end
    
    # Disable file processing in the back end so that 
    # 
    def self.disable_post_processing
      @@disable_file_processing = true
    end
    
    def self.enable_post_processing
      @@disable_file_processing = true
    end
    
  def update_private!(value)
    return false if value != true && value != false
    if value != self.private?
      self.processor_handler.update_private!(value)
    end
  end
  
  def self.update_processor_all(options = {})
    files = DomainFile.find(:all,:conditions => ['file_type != "fld" AND processor != ?',options[:processor]])
    files.each do |file|
      file.update_processor(:processor => options[:processor])
    end
  end
  
  def update_processor(options = {})
    existing_url = self.url
    if(self.processor_handler.copy_local!)
      self.processor_handler.destroy_remote!
      if(Configuration.file_types.processors.include?(options[:processor]))
        if(options[:processor] != 'local')
          self.update_attributes(:processor => 'local',:processor_status => 'processing')
          self.processor = options[:processor]
          if(self.processor_handler.copy_remote!)
            @file_change = true
            self.update_attributes(:processor_status => 'ok') # Should trigger resaving of domain_file_instances
#            unless(options[:new_file])
#             self.notify_file_instances! unless(options[:batch])
#            end
            return true
          else 
            return false
          end
        end
      end
    end
    
   self.update_attributes(:processor => 'local',:processor_status => 'ok')
  end
    
  class LocalProcessor 
    def initialize(df); @df = df; end 
    
    # Don't need to do anything 
    def copy_local!; true; end
    def copy_remote!; true; end
    def destroy_remote!; true; end
    
    def update_private!(value)
      old_directory = @df.abs_storage_directory
      @df.update_attribute(:private,value)
      FileUtils.mkpath(@df.abs_storage_directory)
      
      # Strip off the final directory so we don't move to a subdirectory 
      File.move(old_directory,@df.abs_storage_directory.split("/")[0..-2].join("/"))
    end
    
  end  	
  
  
  def processor_handler
    
    if(self.processor.blank? || self.processor == 'local')
      @processor = LocalProcessor.new(self)
    else
      begin
        cls = self.processor.classify.constantize
        cls.new(self)
      rescue Exception => e
        LocalProcessor.new(self)
      end
    end
  end
  
  
  
  #######
  # Import and Export functions
  ############


  # Create a new DomainFile that is an archive of the this folder
  def download_directory(parameters = {})
    return nil unless self.file_type == 'fld'
    
    dir = DomainFile.generate_temporary_directory
    self.children_cp(dir)
    
    dest_filename = self.name.downcase.gsub(/[ _]+/,"_").gsub(/[^a-z+0-9_]/,"") + ".zip"
    `cd #{dir}; zip -r ../#{dest_filename} *`
    
    df = nil
    File.open(dir + "/../" + dest_filename) do |fp|
      df = DomainFile.create(:filename => fp,:parent_id => self.parent_id)
    end
    
    FileUtils.rm_rf(dir)   
    FileUtils.rm_rf(dir + "/../" + dest_filename)
    
    df
  end
  
  protected 
  
  def children_cp(dir)
    self.children.each do |child|
      if child.file_type == 'fld'
        new_dir = dir + "/" + child.name
        FileUtils.mkpath(new_dir)
        child.children_cp(new_dir)
      else
        File.copy(child.abs_filename,dir)
      end
    end
  end
  
	public
	
	# Extract an archive into a bunch of files, creating 
	def extract(options = {})
    single_folder = options[:single_folder] ? true : false
    extraction_type = options[:file_types] ?  options[:file_types] : nil
    
		files = []
	
		if self.is_archive?
			@dir =  DomainFile.generate_temporary_directory
			 
			m = { 
				"\.tar\.gz" => "tar xzf", 
				"\.tar\.bz2" => "tar xjf", 
				"\.tar" => "tar xf", 
				"\.zip" => "unzip -o" 
			} 
			# Collection Extraction Code used from:
			# http://www.atmos.org/2005/12/14/rails-file-collection-uploads
			# Create the Directory
			
			Dir.chdir(@dir) do 
				filename = self.abs_filename
				# Find which way we need to extract the file,
				# and run the appropriate command
				m.each do |pattern,cmd|
					if filename =~ /#{pattern}$/i 
						IO.popen("#{cmd} #{filename}") { |io| } 
						break
					end 
				end
				# Create a new domain file  for each file in the directory
				files = self.extract_directory(@dir,self.parent_id,single_folder,extraction_type)
			end
      FileUtils.rm_rf(@dir)   
		end 
		return files
	end
	
   def extract_directory(dir,parent_id,single_folder = false,extraction_type = nil)
   		files = []
   		Dir.chdir(dir) do 
   		filenames = []
			Dir.foreach('.') do |file|
			  filenames << file
			end
			filenames.sort!
			filenames.each do |file|
				if File.file?(file)
					# Open the file
					# Create a new domain file and save it
          begin     
					 File.open(file) do |filename|
              df = DomainFile.new(:filename => filename,:parent_id => parent_id)
              df.save
              
              if df.file_type == 'doc'  && !@@public_file_extensions.include?(@upload_file.extension.to_s.downcase)
                df.update_private!(true)
              end
              
              if !extraction_type || extraction_type.include?(df.file_type)
                files << df.id
              else
                df.destroy
              end
            end
          rescue Exception 
            ''
          end
				elsif File.directory?(file) && file  != '.' && file != '..' 
          if !single_folder    
  					df = DomainFile.new(:name => file, :parent_id => parent_id, :file_type => 'fld',:creator_id => self.creator_id)
					  df.save
					  files << df.id
            self.extract_directory(File.join(dir,file),df.id,single_folder,extraction_type)
          else
            files += self.extract_directory(File.join(dir,file),parent_id,single_folder,extraction_type)
          end     
				end
			end
		end
		files
   end
   	
	
   def self.generate_temporary_directory
      fl = DomainFile.new()
   
      time = Time.now.to_s+(Process.pid + Process.pid + fl.object_id).to_s
      dir = File.join(abs_private_storage_base,
                     'tmp',
                      Digest::SHA1.hexdigest(time))   
      FileUtils.mkpath(dir)
      
      dir
   end

  def generate_csv
    if self.extension == 'xls'
      output_csv = "#{self.abs_storage_directory}/converted.csv"
      `xls2csv #{self.filename} > #{output_csv}`
      output_csv
    else
      nil
    end
  end
	
	

 protected 

  def self.generate_prefix
    digest  = Digest::SHA1.hexdigest(Time.now.to_s + rand(1000000000000).to_s)
    "#{digest[0..1]}/#{digest[2..2]}"
  end
 
  # From File Column
  # Safely generate a temporary name
  def self.generate_temp_name
    now = Time.now
    "#{now.to_i}.#{now.usec}.#{Process.pid}"
  end
  
  # From File Column
  # White list to make sure filename is ok
  def self.sanitize_filename(filename)  # :nodoc:
    filename = File.basename(filename.gsub("\\", "/")) # work-around for IE
    filename.gsub!(/[^a-zA-Z0-9\.\-\+_]/,"_")
    filename = "_#{filename}" if filename =~ /^\.+$/
    filename = "unnamed" if filename.size == 0
    filename
  end
   

   
  # Attribution: 
  # This Code and Comment Taken From file_column plugin Verbatim
  #
  # This bit of code allows you to pass regular old files to
  # file_column.  file_column depends on a few extra methods that the
  # CGI uploaded file class adds.  We will add the equivalent methods
  # to file objects if necessary by extending them with this module. This
  # avoids opening up the standard File class which might result in
  # naming conflicts.

  module FileCompat # :nodoc:
    def original_filename
      File.basename(path)
    end
    
    def size
      File.size(path)
    end
    
    def local_path
      path
    end
    
    def content_type
      nil
    end
  end   
  
end