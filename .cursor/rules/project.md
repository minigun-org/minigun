# Project: Localize - Translation Management System

## Tech Stack
- Backend:
  - Rails 8.x
  - MongoDB with Mongoid ODM
  - Slim templates (Rails) - NEVER use ERB
- Frontend:
  - React + TypeScript (Frontend engine)
  - Tailwind CSS (React)
- Client libaries in various languages

## Architecture
- Core Rails/React app in `engines/` dir:
    - **Core**: Models and business logic (`Localize::Project`, `Localize::User`)
    - **Backend**: Admin/web API controllers (`Localize::Backend::ProjectsController`)
    - **Frontend**: React SPA in `engines/frontend/` with Tailwind CSS
    - **API**: Public REST API (`Localize::Api::ProjectsController`)
- Client libraries in `clients/` dir.
    - `clients/react-i18next-editor` Plugin for React+I18next.

## Code Conventions

### Models (Mongoid)
- Location: `engines/core/app/models/localize/`
- Include `Mongoid::Document` and `Mongoid::Timestamps`
- Use typed fields: `field :name, type: String`
- Add indexes: `index({ field: 1 })`
- Namespaced references: `belongs_to :team, class_name: 'Localize::Team'`

### Controllers
- Use `fetch_` prefix for before_actions (NOT `set_`)
  ```ruby
  before_action :fetch_project

  def fetch_project
    @project = Localize::Project.find(params[:id])
  end
  ```
- Check access: `@project.project_users.where(user: current_user).exists?`
- API responses: `render json: { success: true, data: {...} }`
- Always use namespaced models: `Localize::Project.find(...)`

### Templates
- Rails: **ALWAYS use Slim** (`.html.slim`) - NEVER ERB
- React: Use Tailwind CSS
