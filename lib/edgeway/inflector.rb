module Edgeway
  module Inflector
    # "admin_posts" -> "AdminPosts"
    def self.camelize(name) = name.split("_").map(&:capitalize).join

    # "admin/posts" -> "Admin::PostsController"
    def self.controller_class_name(path)
      path.split("/").map { |part| camelize(part) }.join("::") + "Controller"
    end

    def self.singularize(name)
      n = name.to_s
      return n[0...-3] + "y" if n.end_with?("ies")
      if n.end_with?("es")
        stem = n[0...-2]
        return stem if sibilant?(stem)
      end
      return n if n.end_with?("ss") || n.end_with?("us")
      return n[0...-1] if n.end_with?("s")
      n
    end

    def self.pluralize(name)
      n = name.to_s
      return n[0...-1] + "ies" if n.end_with?("y") && n.length > 1 && !"aeiou".include?(n[-2])
      return n + "es" if n.end_with?("s") || n.end_with?("x") || n.end_with?("sh") || n.end_with?("ch")
      n + "s"
    end

    def self.sibilant?(stem)
      stem.end_with?("ss") || (stem.end_with?("us") && !stem.end_with?("ous")) || stem.end_with?("x") ||
        stem.end_with?("sh") || stem.end_with?("ch")
    end
  end
end
